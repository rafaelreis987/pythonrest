import base64
import os
from io import StringIO
from pymysql import *
from databaseconnector.JSONDictHelper import retrieve_json_from_sql_query
from sshtunnel import SSHTunnelForwarder
import paramiko


def write_cert_to_pem_file(cert_bytes, file_path, key_type):
    pem_string = format_pem(cert_bytes, key_type)
    with open(file_path, 'w') as f:
        f.write(pem_string)


def format_pem(base64_data, key_type):
    cert_bytes = base64.b64decode(base64_data)
    pem = base64.b64encode(cert_bytes).decode('utf-8')
    pem_lines = "\n".join(
        [pem[i:i + 64] for i in range(0, len(pem), 64)])

    if key_type == "PRIVATE KEY":
        return f"-----BEGIN PRIVATE KEY-----\n{pem_lines}\n-----END PRIVATE KEY-----"
    else:
        return f"-----BEGIN CERTIFICATE-----\n{pem_lines}\n-----END CERTIFICATE-----"


def get_mysql_db_connection_with_ssl(_host, _user, _password, _database, ssl_ca_bytes, ssl_cert_bytes, ssl_key_bytes, _port, ssl_hostname):
    try:
        ssl_ca_file_path = 'ca.pem'
        ssl_key_file_path = 'key.pem'
        ssl_cert_file_path = 'cert.pem'

        write_cert_to_pem_file(ssl_ca_bytes, ssl_ca_file_path, "CERTIFICATE")
        write_cert_to_pem_file(ssl_key_bytes, ssl_key_file_path, "PRIVATE KEY")
        write_cert_to_pem_file(ssl_cert_bytes, ssl_cert_file_path, "CERTIFICATE")

        con = connect(
            host=ssl_hostname,
            port=_port,
            user=_user,
            password=_password,
            db=_database,
            ssl={
                'ca': ssl_ca_file_path,
                'cert': ssl_cert_file_path,
                'key': ssl_key_file_path,
                'check_hostname': False,
                'ssl_verify_cert': False
            }
        )
        cursor = con.cursor()
        return cursor

    except Exception as e:
        raise e
    finally:
        for file_path in [ssl_ca_file_path, ssl_key_file_path, ssl_cert_file_path]:
            if os.path.exists(file_path):
                os.remove(file_path)


def get_mysql_db_connection_with_ssh_publickey(
        _host, _port, _user, _password, _database, ssh_host, ssh_port, ssh_user, ssh_pkey_bytes, ssh_local_bind_port
):
    tunnel = None
    try:
        private_key_binary = base64.b64decode(ssh_pkey_bytes)

        pkey_file = StringIO(private_key_binary.decode())
        pkey = paramiko.RSAKey.from_private_key(pkey_file)

        tunnel = SSHTunnelForwarder(
            ssh_address_or_host=(ssh_host, ssh_port),
            ssh_username=ssh_user,
            ssh_pkey=pkey,
            remote_bind_address=(_host, _port),
            local_bind_address=(ssh_host, ssh_local_bind_port),
            set_keepalive=10
        )

        tunnel.start()

        con = connect(
            host=_host,
            user=_user,
            password=_password,
            db=_database,
            port=tunnel.local_bind_port
        )

        cursor = con.cursor()
        return cursor

    except Exception as e:
        print(f"Failed to connect: {e}")


def get_mysql_db_connection_with_ssh_password(
        _host, _port, _user, _password, _database, ssh_host, ssh_port, ssh_user, ssh_password, ssh_local_bind_port
):
    try:
        tunnel = SSHTunnelForwarder(
            ssh_address_or_host=(ssh_host, ssh_port),
            ssh_username=ssh_user,
            ssh_password=ssh_password,
            remote_bind_address=(_host, _port),
            local_bind_address=(ssh_host, ssh_local_bind_port),
            set_keepalive=10
        )

        tunnel.start()

        con = connect(
            host=_host,
            user=_user,
            password=_password,
            db=_database,
            port=tunnel.local_bind_port
        )

        cursor = con.cursor()
        return cursor

    except Exception as e:
        print(f"Failed to connect: {e}")


def get_mysql_db_connection(_host, _port, _user, _password, _database):
    con = connect(host=_host, port=_port, user=_user,
                  password=_password, database=_database)
    cursor = con.cursor()
    return cursor


def retrieve_table_constraints(schema, table_name, connected_schema):
    sql_query = """
    SELECT * 
    FROM information_schema.TABLE_CONSTRAINTS 
    WHERE CONSTRAINT_TYPE='FOREIGN KEY' 
      AND TABLE_SCHEMA=%s 
      AND TABLE_NAME=%s
    """

    params = (schema, table_name)

    return retrieve_json_from_sql_query(sql_query, connected_schema, params)


def convert_retrieved_table_name_tuple_list_from_connected_schema(tuple_name_list):
    table_list = list()
    for table in tuple_name_list:
        table_list.append(table[0])
    return table_list


def retrieve_table_name_tuple_list_from_connected_schema(connected_schema):
    connected_schema.execute("""
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'
    """)
    response = connected_schema.fetchall()

    return response



def retrieve_table_field_metadata(table_name, connected_schema):
    try:
        return retrieve_json_from_sql_query(f'SHOW FIELDS FROM {table_name}', connected_schema)
    except:
        return retrieve_json_from_sql_query(f'SHOW FIELDS FROM `{table_name}`', connected_schema)


def retrieve_table_relative_column_constraints(column_name, table_name, schema, connected_schema):
    sql_query = """
    SELECT `REFERENCED_TABLE_NAME`, `REFERENCED_COLUMN_NAME`, `COLUMN_NAME`
    FROM `information_schema`.`KEY_COLUMN_USAGE`
    WHERE `CONSTRAINT_SCHEMA` = %s AND `REFERENCED_TABLE_SCHEMA` IS NOT NULL 
      AND `REFERENCED_TABLE_NAME` IS NOT NULL AND `COLUMN_NAME` = %s 
      AND `TABLE_NAME` = %s AND `REFERENCED_COLUMN_NAME` IS NOT NULL;
    """

    params = (schema, column_name, table_name)

    result = retrieve_json_from_sql_query(sql_query, connected_schema, params)
    return result[0] if result else {}
