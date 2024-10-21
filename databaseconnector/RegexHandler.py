import re
from pathlib import Path
import os


def read_file_as_bytes(file_path):
    with open(file_path, "rb") as pem_file:
        return pem_file.read()


def extract_ssl_params(connection_string):
    path_pattern = re.compile(r"ssl:\/\/ssl_ca=([^?]+)\?ssl_cert=([^?]+)\?ssl_key=([^?]+)\?hostname=([^?]+)")
    byte_pattern = re.compile(
        r"ssl:\/\/ssl_ca_bytes=([^?]+)\?ssl_cert_bytes=([^?]+)\?ssl_key_bytes=([^?]+)\?hostname=([^?]+)"
    )

    match = path_pattern.match(connection_string)

    if match:
        ssl_ca_path = Path(match.group(1)).as_posix()
        ssl_cert_path = Path(match.group(2)).as_posix()
        ssl_key_path = Path(match.group(3)).as_posix()

        ssl_ca_bytes = read_file_as_bytes(ssl_ca_path)
        ssl_cert_bytes = read_file_as_bytes(ssl_cert_path)
        ssl_key_bytes = read_file_as_bytes(ssl_key_path)

        # Definindo variáveis de ambiente como strings
        os.environ['ssl_ca_bytes'] = ssl_ca_bytes.decode('utf-8')  # Remove o 'b' e converte para string
        os.environ['ssl_cert_bytes'] = ssl_cert_bytes.decode('utf-8')
        os.environ['ssl_key_bytes'] = ssl_key_bytes.decode('utf-8')
        os.environ['ssl_hostname'] = match.group(4)

        return {
            "ssl_ca_bytes": ssl_ca_bytes,
            "ssl_cert_bytes": ssl_cert_bytes,
            "ssl_key_bytes": ssl_key_bytes,
            "ssl_hostname": match.group(4),
        }

    match = byte_pattern.match(connection_string)

    if match:
        ssl_ca_bytes = match.group(1).encode('utf-8')
        ssl_cert_bytes = match.group(2).encode('utf-8')
        ssl_key_bytes = match.group(3).encode('utf-8')

        # Definindo variáveis de ambiente como strings
        os.environ['ssl_ca_bytes'] = ssl_ca_bytes.decode('utf-8')
        os.environ['ssl_cert_bytes'] = ssl_cert_bytes.decode('utf-8')
        os.environ['ssl_key_bytes'] = ssl_key_bytes.decode('utf-8')
        os.environ['ssl_hostname'] = match.group(4)

        return {
            "ssl_ca_bytes": ssl_ca_bytes,
            "ssl_cert_bytes": ssl_cert_bytes,
            "ssl_key_bytes": ssl_key_bytes,
            "ssl_hostname": match.group(4),
        }

    raise ValueError("Invalid SSL connection string format.")


def extract_ssh_publickey_params(connection_string):
    path_pattern = re.compile(
        r"ssh:\/\/([^@]+)@([^:]+):(\d+)\?key_path=([A-Za-z]:[\\\/].+|[\\\/].+)\?local_bind_port=(\d+)")
    byte_pattern = re.compile(r"ssh:\/\/([^@]+)@([^:]+):(\d+)\?key_bytes=([^?]+)\?local_bind_port=(\d+)")

    match = path_pattern.match(connection_string)

    if match:
        ssh_key_path = Path(match.group(4)).as_posix()
        ssh_key_bytes = read_file_as_bytes(ssh_key_path)

        return {
            "ssh_user": match.group(1),
            "ssh_host": match.group(2),
            "ssh_port": int(match.group(3)),
            "ssh_key_bytes": ssh_key_bytes,
            "ssh_local_bind_port": int(match.group(5)),
        }

    match = byte_pattern.match(connection_string)

    if match:
        ssh_key_bytes = match.group(4)

        return {
            "ssh_user": match.group(1),
            "ssh_host": match.group(2),
            "ssh_port": int(match.group(3)),
            "ssh_key_bytes": ssh_key_bytes,
            "ssh_local_bind_port": int(match.group(5)),
        }

    raise ValueError("Invalid SSH connection string format.")


def extract_ssh_params(connection_string):
    pattern = re.compile(r"ssh:\/\/([^:]+):([^@]+)@([^:]+):(\d+)(?:\?local_bind_port=(\d+))?")
    match = pattern.match(connection_string)

    if match:
        return {
            "ssh_user": match.group(1),
            "ssh_password": match.group(2),
            "ssh_host": match.group(3),
            "ssh_port": int(match.group(4)),
            "ssh_local_bind_port": int(match.group(5)),
        }
    else:
        raise ValueError("Invalid SSH connection string format.")


def extract_mysql_params(connection_string):
    pattern = re.compile(r"mysql:\/\/([^:]+):([^@]+)@([^:]+):([^\/]+)\/(.+)")
    match = pattern.match(connection_string)

    if match:
        return {
            "mysql_user": match.group(1),
            "mysql_password": match.group(2),
            "mysql_host": match.group(3),
            "mysql_port": int(match.group(4)),
            "mysql_schema": match.group(5),
        }
    else:
        raise ValueError("Invalid MySQL connection string format.")


def validate_postgres_connection_string(connection_string):
    pattern = re.compile(
        r"postgresql:\/\/([^:]+):([^@]+)@([^:]+):([^\/]+)\/([^?]+)\?options=-c%20search_path=([^,]+),public")
    match = pattern.match(connection_string)

    if match:
        return True
    else:
        return False


def extract_postgres_params(connection_string):
    if validate_postgres_connection_string(connection_string):
        pattern = re.compile(
            r"postgresql:\/\/([^:]+):([^@]+)@([^:]+):([^\/]+)\/([^?]+)\?options=-c%20search_path=([^,]+),public")
        match = pattern.match(connection_string)

        return {
            "pgsql_user": match.group(1),
            "pgsql_password": match.group(2),
            "pgsql_host": match.group(3),
            "pgsql_port": int(match.group(4)),
            "pgsql_database_name": match.group(5),
            "pgsql_schema": match.group(6),
        }
    else:
        raise ValueError(
            "Invalid PostgreSQL connection string format. Please use the pattern 'postgresql://{user}:{password}@{host}:{port}/{database}?options=-c%20search_path={schema},public'.")


def extract_sqlserver_params(connection_string):
    pattern = re.compile(r"mssql:\/\/([^\:]+):([^\@]+)@([^\:]+):([^\:]+)\/(.+)")
    match = pattern.match(connection_string)

    if match:
        return {
            "mssql_user": match.group(1),
            "mssql_password": match.group(2),
            "mssql_host": match.group(3),
            "mssql_port": int(match.group(4)),
            "mssql_schema": match.group(5),
        }
    else:
        raise ValueError("Invalid SQL Server connection string format.")


def extract_mariadb_params(connection_string):
    pattern = re.compile(r"mariadb:\/\/([^\:]+):([^\@]+)@([^\:]+):([^\:]+)\/(.+)")
    match = pattern.match(connection_string)

    if match:
        return {
            "mariadb_user": match.group(1),
            "mariadb_password": match.group(2),
            "mariadb_host": match.group(3),
            "mariadb_port": int(match.group(4)),
            "mariadb_schema": match.group(5),
        }
    else:
        raise ValueError("Invalid MariaDB connection string format.")


def transform_table_name_to_pascal_case_class_name(table_name):
    # Remove special characters (including underscores) and split the name into words
    words = re.findall(r'[a-zA-Z0-9]+', table_name)

    # Convert the words to PascalCase
    pascal_case_name = ''.join(word.capitalize() for word in words)

    return pascal_case_name
