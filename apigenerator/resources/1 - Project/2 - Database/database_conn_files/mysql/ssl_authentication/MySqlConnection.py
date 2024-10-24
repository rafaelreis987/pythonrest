import base64
import os

import pymysql
from src.e_Infra.GlobalVariablesManager import *

mysql_internet_conn = None


def get_mysql_connection_schema_internet():
    global mysql_internet_conn

    if not mysql_internet_conn:
        try:
            ssl_ca_file_path = 'ca.pem'
            ssl_key_file_path = 'key.pem'
            ssl_cert_file_path = 'cert.pem'

            write_ssl_bytes_to_pem_file(get_global_variable('ssl_ca_bytes'), ssl_ca_file_path, "CERTIFICATE")
            write_ssl_bytes_to_pem_file(get_global_variable('ssl_key_bytes'), ssl_key_file_path, "PRIVATE KEY")
            write_ssl_bytes_to_pem_file(get_global_variable('ssl_cert_bytes'), ssl_cert_file_path, "CERTIFICATE")

            mysql_internet_conn = 'mysql+pymysql://' + get_global_variable('mysql_user') + ':' \
                                  + get_global_variable('mysql_password') + '@' \
                                  + get_global_variable('ssl_hostname') + ':' \
                                  + get_global_variable('mysql_port') + '/' \
                                  + get_global_variable('mysql_schema') + '?' \
                                  + 'ssl_ca=' + ssl_ca_file_path + '&' \
                                  + 'ssl_cert=' + ssl_cert_file_path + '&' \
                                  + 'ssl_key=' + ssl_key_file_path + '&' \
                                  + 'ssl_verify_cert=true&' \
                                  + 'ssl_verify_identity=true'

        except Exception as e:
            print(f"Erro ao configurar a conexão SSL: {e}")
            raise e
        finally:
            for file_path in [ssl_ca_file_path, ssl_key_file_path, ssl_cert_file_path]:
                if os.path.exists(file_path):
                    os.remove(file_path)

        return mysql_internet_conn


def write_ssl_bytes_to_pem_file(cert_bytes, file_path, key_type):
    pem_string = format_pem(cert_bytes, key_type)
    with open(file_path, 'w') as f:
        f.write(pem_string)


def format_pem(base64_data, key_type):
    cert_bytes = base64.b64decode(base64_data)
    pem = base64.b64encode(cert_bytes).decode('utf-8')
    pem_lines = "\n".join(
        [pem[i:i + 64] for i in range(0, len(pem), 64)])

    if key_type == "PRIVATE KEY":
        return f"-----BEGIN PRIVATE KEY-----\n{pem_lines}\n-----END PRIVATE KEY-----\n"
    else:
        return f"-----BEGIN CERTIFICATE-----\n{pem_lines}\n-----END CERTIFICATE-----\n"
