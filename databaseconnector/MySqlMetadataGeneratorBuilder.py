import base64
import os
from io import StringIO
from pymysql import *
from databaseconnector.JSONDictHelper import retrieve_json_from_sql_query
from sshtunnel import SSHTunnelForwarder
import paramiko
import tempfile


def read_cert_from_pem_file(file_path):
    with open(file_path, 'rb') as f:
        pem_data = f.read()

    if b"PRIVATE KEY" in pem_data:
        pem_data = pem_data.replace(b"-----BEGIN PRIVATE KEY-----\n", b"")
        pem_data = pem_data.replace(b"-----END PRIVATE KEY-----\n", b"")
    else:
        pem_data = pem_data.replace(b"-----BEGIN CERTIFICATE-----\n", b"")
        pem_data = pem_data.replace(b"-----END CERTIFICATE-----\n", b"")

    pem_data = pem_data.replace(b'\r\n', b'').replace(b'\n', b'')

    return pem_data


def write_cert_to_file(cert_content, prefix, suffix):
    if isinstance(cert_content, bytes):
        cert_content = cert_content.decode('utf-8')
    temp_file = tempfile.NamedTemporaryFile(delete=False, prefix=prefix, suffix=suffix, mode='w')
    temp_file.write(cert_content)
    temp_file.close()
    return temp_file.name


def format_pem(cert_bytes, key_type):
    pem = base64.b64encode(cert_bytes).decode('utf-8')
    pem_lines = "\n".join(
        [pem[i:i + 64] for i in range(0, len(pem), 64)])

    if key_type == "PRIVATE KEY":
        return f"-----BEGIN PRIVATE KEY-----\n{pem_lines}\n-----END PRIVATE KEY-----"
    else:
        return f"-----BEGIN CERTIFICATE-----\n{pem_lines}\n-----END CERTIFICATE-----"


def get_mysql_db_connection_with_ssl(_host, _user, _password, _schema, ssl_ca, ssl_cert, ssl_key, _port, ssl_hostname):
    connection = None

    try:
        ca_file = write_cert_to_file(ssl_ca, 'ca_', '.pem')
        cert_file = write_cert_to_file(ssl_cert, 'cert_', '.pem')
        key_file = write_cert_to_file(ssl_key, 'key_', '.pem')

        ssl = {
            'ssl_ca': ca_file,
            'ssl_cert': cert_file,
            'ssl_key': key_file,
            'check_hostname': False
        }

        con = connect(
            user=_user,
            password=_password,
            host=ssl_hostname,
            port=_port,
            database=_schema,
            ssl_ca=ca_file,
            ssl_cert=cert_file,
            ssl_key=key_file
        )


        cursor = con.cursor()
        return cursor

    except Exception as e:
        print(f"Failed to connect: {e}")
        return None

    finally:
        for file_path in [ca_file, cert_file, key_file]:
            if file_path and os.path.exists(file_path):
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
    connected_schema.execute('SHOW tables')
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
