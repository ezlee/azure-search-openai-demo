#!/bin/sh

echo 'Creating Python virtual environment ".venv"...'
# Use python (3.10.19) instead of python3 (which defaults to 3.9)
python -m venv .venv

echo 'Installing dependencies from "requirements.txt" into virtual environment...'
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install certifi

# Set Python to use certifi certificates for SSL verification
export CERT_PATH=$(.venv/bin/python -c "import certifi; print(certifi.where())")
export SSL_CERT_FILE=$CERT_PATH

.venv/bin/python -m pip install -r app/backend/requirements.txt

if [ $? -ne 0 ]; then
  echo "Failed to install dependencies"
  exit 1
fi
