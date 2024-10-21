import pymysql
from sshtunnel import SSHTunnelForwarder
import base64
from io import StringIO
import paramiko

from src.e_Infra.GlobalVariablesManager import *

tunnel = None


def get_mysql_connection_schema_internet():
    global tunnel

    if not tunnel:
        try:
            ssh_pkey_bytes = get_global_variable('ssh_key_bytes')

            if ssh_pkey_bytes is None or ssh_pkey_bytes == '':
                raise ValueError("A chave privada SSH não foi configurada corretamente.")

            private_key_binary = base64.b64decode(ssh_pkey_bytes)

            pkey_file = StringIO(private_key_binary.decode())
            pkey = paramiko.RSAKey.from_private_key(pkey_file)

            tunnel = SSHTunnelForwarder(
                ssh_address_or_host=(get_global_variable('ssh_host'), int(get_global_variable('ssh_port'))),
                ssh_username=get_global_variable('ssh_user'),
                ssh_pkey=pkey,
                remote_bind_address=(get_global_variable('mysql_host'), int(get_global_variable('mysql_port'))),
                local_bind_address=(get_global_variable('ssh_host'), int(get_global_variable('ssh_local_bind_port'))),
                set_keepalive=10
            )

            tunnel.start()

            mysql_conn_string = 'mysql+pymysql://' + get_global_variable('mysql_user') + ':' \
                                + get_global_variable('mysql_password') + '@' \
                                + get_global_variable('mysql_host') + ':' \
                                + str(tunnel.local_bind_port) + '/' \
                                + get_global_variable('mysql_schema')
        except Exception as e:
            print(f"Erro ao configurar o túnel SSH: {e}")
            raise

    return mysql_conn_string
