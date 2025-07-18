import base64
import os
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

    def decrypt(self, ciphertext):
        data = base64.b64decode(ciphertext.encode('utf-8'))
        iv = data[:12]
        tag = data[12:28]
        encrypted = data[28:]
        decryptor = Cipher(
            algorithms.AES(self.key),
            modes.GCM(iv, tag),
        ).decryptor()
        return decryptor.update(encrypted) + decryptor.finalize()
