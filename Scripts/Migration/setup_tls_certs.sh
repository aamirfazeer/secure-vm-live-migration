#!/bin/bash

# TLS Certificate Setup for QEMU Migration
# Run this script on both source and destination machines

CERT_DIR="/etc/pki/qemu"
CA_KEY="$CERT_DIR/ca-key.pem"
CA_CERT="$CERT_DIR/ca-cert.pem"
SERVER_KEY="$CERT_DIR/server-key.pem"
SERVER_CERT="$CERT_DIR/server-cert.pem"
CLIENT_KEY="$CERT_DIR/client-key.pem"
CLIENT_CERT="$CERT_DIR/client-cert.pem"

SOURCE_IP="10.22.196.155"
DESTINATION_IP="10.22.196.158"

echo ">>> Setting up TLS certificates for QEMU migration"

# Create certificate directory
sudo mkdir -p $CERT_DIR
cd $CERT_DIR

# Generate CA private key
echo ">>> Generating CA private key..."
sudo openssl genrsa -out $CA_KEY 2048

# Generate CA certificate
echo ">>> Generating CA certificate..."
sudo openssl req -new -x509 -days 3650 -key $CA_KEY -out $CA_CERT -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=QEMU-CA"

# Generate server private key
echo ">>> Generating server private key..."
sudo openssl genrsa -out $SERVER_KEY 2048

# Generate server certificate request
echo ">>> Generating server certificate..."
sudo openssl req -new -key $SERVER_KEY -out server-req.pem -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=$DESTINATION_IP"

# Sign server certificate
sudo openssl x509 -req -days 365 -in server-req.pem -CA $CA_CERT -CAkey $CA_KEY -CAcreateserial -out $SERVER_CERT

# Generate client private key
echo ">>> Generating client private key..."
sudo openssl genrsa -out $CLIENT_KEY 2048

# Generate client certificate request
echo ">>> Generating client certificate..."
sudo openssl req -new -key $CLIENT_KEY -out client-req.pem -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=$SOURCE_IP"

# Sign client certificate
sudo openssl x509 -req -days 365 -in client-req.pem -CA $CA_CERT -CAkey $CA_KEY -CAcreateserial -out $CLIENT_CERT

# Clean up temporary files
sudo rm server-req.pem client-req.pem

# Set proper permissions
sudo chmod 600 $CA_KEY $SERVER_KEY $CLIENT_KEY
sudo chmod 644 $CA_CERT $SERVER_CERT $CLIENT_CERT
sudo chown root:root $CERT_DIR/*

echo ">>> TLS certificates created successfully in $CERT_DIR"
echo ">>> Certificate files:"
ls -la $CERT_DIR/

echo ""
echo ">>> Copy these certificates to the other machine:"
echo "scp -r $CERT_DIR root@OTHER_IP:/etc/pki/"
echo ""
echo ">>> Verify certificates:"
echo "openssl verify -CAfile $CA_CERT $SERVER_CERT"
echo "openssl verify -CAfile $CA_CERT $CLIENT_CERT"
