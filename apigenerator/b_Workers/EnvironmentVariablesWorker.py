import json
import os
from shutil import copytree, copy
from apigenerator.g_Utils.OpenFileExeHandler import open
import base64
from cryptography.hazmat.primitives.ciphers import (
    Cipher, algorithms, modes
)

class Encryption:
    def __init__(self, key):
        self.key = key

    def encrypt(self, plaintext):
        iv = os.urandom(12)
        encryptor = Cipher(
            algorithms.AES(self.key),
            modes.GCM(iv),
        ).encryptor()
        ciphertext = encryptor.update(plaintext) + encryptor.finalize()
        return base64.b64encode(iv + encryptor.tag + ciphertext).decode('utf-8')

def install_environment_variables(result, us_datetime, db, db_params, script_absolute_path, uid_type, db_secure_connection_params=None):
    # Installs and configures environment variables in environment variables file.
    print('Adding Environment Variables to API')
    copytree(os.path.join(script_absolute_path, 'apigenerator/resources/3 - Variables/EnvironmentVariablesFile'),
             os.path.join(result, 'src', 'e_Infra', 'g_Environment'), dirs_exist_ok=True)
    copy(os.path.join(script_absolute_path, 'apigenerator/resources/1 - Project/1 - BaseProject/src/e_Infra/g_Environment/Encryption.py'),
         os.path.join(result, 'src', 'e_Infra', 'g_Environment'))

    key = os.urandom(32)
    encryption = Encryption(key)

    env_file_path = os.path.join(result, 'src', 'e_Infra', 'g_Environment', 'EnvironmentVariables.py')

    with open(env_file_path, 'r') as env_in:
        content = env_in.readlines()

    with open(env_file_path, 'w') as env_out:
        for line in content:
            if "os.environ['CYPHER_TEXT']" in line:
                line = "os.environ['CYPHER_TEXT'] = '{}'\n".format(key.hex())

            if '# Database start configuration #' in line:
                encrypted_db = encryption.encrypt(str(db).encode())
                append_line = "os.environ['main_db_conn'] = '{}'\n".format(encrypted_db)
                line = line + append_line

            if '# Configuration for database connection #' in line:
                append_line = ''
                for key_param in db_params:
                    encrypted_param = encryption.encrypt(str(db_params[key_param]).encode())
                    append_line = append_line + "os.environ['{}'] = '{}'\n".format(key_param, encrypted_param)
                line = line + append_line

                if db_secure_connection_params:
                    append_line = ''
                    for key_param in db_secure_connection_params:
                        encrypted_param = encryption.encrypt(str(db_secure_connection_params[key_param]).encode())
                        append_line = append_line + "os.environ['{}'] = '{}'\n".format(key_param, encrypted_param)
                    line = line + append_line

            if '# UID Generation Type #' in line:
                encrypted_uid_type = encryption.encrypt(str(uid_type).encode())
                append_line = "os.environ['id_generation_method'] = '{}'\n".format(encrypted_uid_type)
                line = line + append_line

            env_out.write(line)

    install_datetime_masks(result, us_datetime)


def install_datetime_masks(result, us_datetime):
    if us_datetime:
        with open(os.path.join(result, 'src', 'e_Infra', 'g_Environment', 'EnvironmentVariables.py'), 'r') as env_in:
            env_file_lines = env_in.readlines()
        with open(os.path.join(result, 'src', 'e_Infra', 'g_Environment', 'EnvironmentVariables.py'), 'w') as env_out:
            for line in env_file_lines:
                env_out.write(line.replace("%Y-%m-%d, %d-%m-%Y, %Y/%m/%d, %d/%m/%Y",
                                           "%Y-%m-%d, %m-%d-%Y, %Y/%m/%d, %m/%d/%Y"))
