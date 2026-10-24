"""Throwaway house CA, server certificate and client certificates."""

import datetime
import ipaddress
import os

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def _name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def _cert(subject, key, issuer=None, issuer_key=None, ca=False, server=False):
    now = datetime.datetime.now(datetime.timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(_name(subject))
               .issuer_name(issuer.subject if issuer else _name(subject))
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(now - datetime.timedelta(minutes=1)).not_valid_after(now + datetime.timedelta(hours=1)))
    builder = builder.add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), False)
    builder = builder.add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(
        (issuer_key or key).public_key()), False)
    if ca:
        builder = builder.add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        builder = builder.add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
    elif server:
        builder = builder.add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), False)
        builder = builder.add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), False)
    else:
        builder = builder.add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), False)
    return builder.sign(issuer_key or key, hashes.SHA256())


def write(directory, client_cn="rails"):
    os.makedirs(directory, exist_ok=True)
    ca_key = ec.generate_private_key(ec.SECP256R1())
    ca = _cert("house test CA", ca_key, ca=True)
    server_key = ec.generate_private_key(ec.SECP256R1())
    server = _cert("souls-house-comms-telegram", server_key, ca, ca_key, server=True)
    client_key = ec.generate_private_key(ec.SECP256R1())
    client = _cert(client_cn, client_key, ca, ca_key)
    files = {}
    for name, obj in (("ca", ca), ("server_cert", server), ("client_cert", client)):
        files[name] = os.path.join(directory, f"{name}.pem")
        with open(files[name], "wb") as handle:
            handle.write(obj.public_bytes(serialization.Encoding.PEM))
    for name, key in (("server_key", server_key), ("client_key", client_key)):
        files[name] = os.path.join(directory, f"{name}.pem")
        with open(files[name], "wb") as handle:
            handle.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()))
    def issue(cn):
        key = ec.generate_private_key(ec.SECP256R1())
        cert = _cert(cn, key, ca, ca_key)
        cert_path, key_path = os.path.join(directory, f"{cn}.pem"), os.path.join(directory, f"{cn}.key")
        with open(cert_path, "wb") as handle:
            handle.write(cert.public_bytes(serialization.Encoding.PEM))
        with open(key_path, "wb") as handle:
            handle.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()))
        return cert_path, key_path
    files["issue"] = issue
    return files
