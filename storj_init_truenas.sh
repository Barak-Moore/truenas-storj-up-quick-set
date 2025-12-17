#!/bin/bash
set -e

# Storj-Up Complete Initialization Script for TrueNAS
# This script initializes storj-up from scratch on a TrueNAS dataset

echo "=========================================="
echo "Storj-Up Complete Setup (TrueNAS)"
echo "=========================================="
echo ""

# Detect script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Script location: $SCRIPT_DIR"
echo ""

# Check if storj-up binary exists in current directory
if [ ! -f "$SCRIPT_DIR/storj-up" ]; then
    echo "Error: storj-up binary not found in $SCRIPT_DIR"
    echo ""
    echo "Please ensure you've placed the storj-up binary in this directory."
    echo "You can download it from: https://github.com/storj/up"
    echo ""
    read -p "Enter path to storj-up binary (or press Ctrl+C to exit): " STORJ_BINARY

    if [ ! -f "$STORJ_BINARY" ]; then
        echo "Error: File not found: $STORJ_BINARY"
        exit 1
    fi

    # Copy binary to script directory
    cp "$STORJ_BINARY" "$SCRIPT_DIR/storj-up"
    chmod +x "$SCRIPT_DIR/storj-up"
    echo "Binary copied to $SCRIPT_DIR/storj-up"
    echo ""
else
    echo "Found storj-up binary: $SCRIPT_DIR/storj-up"
    chmod +x "$SCRIPT_DIR/storj-up"
    echo ""
fi

# Change to script directory for all operations
cd "$SCRIPT_DIR"

# Check if already initialized
EXISTING_INSTALL=false
if [ -f "$SCRIPT_DIR/docker-compose.yaml" ]; then
    EXISTING_INSTALL=true
    echo "=========================================="
    echo "EXISTING INSTALLATION DETECTED"
    echo "=========================================="
    echo ""
    echo "An existing Storj-Up installation was found in this directory."
    echo ""
    echo "You have two options:"
    echo ""
    echo "  1. Apply HTTPS configuration only (recommended)"
    echo "     - Configures HTTPS for gateway-mt"
    echo "     - Sets up port bindings with your IP"
    echo "     - Preserves all existing data and settings"
    echo ""
    echo "  2. Full reinstall"
    echo "     - Backs up existing configuration"
    echo "     - Reinitializes from scratch"
    echo "     - WARNING: May require reconfiguration"
    echo ""
    read -p "Choose option (1 = HTTPS only, 2 = Full reinstall): " INSTALL_OPTION
    echo ""

    if [ "$INSTALL_OPTION" = "1" ]; then
        echo "Selected: Apply HTTPS configuration only"
        echo ""
    elif [ "$INSTALL_OPTION" = "2" ]; then
        echo "Selected: Full reinstall"
        echo ""
        # Backup existing files
        BACKUP_DIR="$SCRIPT_DIR/backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        echo "Backing up existing configuration to: $BACKUP_DIR"
        mv docker-compose.yaml "$BACKUP_DIR/" 2>/dev/null || true
        mv .env "$BACKUP_DIR/" 2>/dev/null || true
        echo "Backup complete."
        echo ""
        EXISTING_INSTALL=false
    else
        echo "Invalid option. Exiting."
        exit 1
    fi
fi

# Get IP address for services
echo "Enter the TrueNAS IP address to run storj-up services on."
echo ""
read -p "IP Address (e.g., 192.168.1.100): " IP_ADDRESS

# Validate IP address format
if [[ ! $IP_ADDRESS =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format"
    exit 1
fi

echo ""
echo "=========================================="
echo "Configuration Summary:"
echo "=========================================="
echo "  Installation Directory: $SCRIPT_DIR"
echo "  IP Address: $IP_ADDRESS"
echo "  Services: minimal, satellite-core, satellite-admin, edge, db, billing"
echo "  Persistent Storage: db, storagenode, auth"
echo ""
echo "  Web UI Port: 10000"
echo "  S3 Gateway (HTTPS): 9999"
echo "  S3 Gateway (HTTP): 20010"
echo "  Linksharing Port: 9090"
echo "  Authservice Port: 8888"
echo "=========================================="
echo ""

read -p "Continue with initialization? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Skip initialization steps if this is an existing install with HTTPS-only config
if [ "$EXISTING_INSTALL" = false ]; then
    # Step 1: Initialize storj-up with required services
    echo ""
    echo "=== Step 1: Initializing Storj-Up ==="
    echo "Running: ./storj-up init minimal,satellite-core,satellite-admin,edge,db,billing"
    ./storj-up init minimal,satellite-core,satellite-admin,edge,db,billing

    if [ $? -ne 0 ]; then
        echo "Error: storj-up init failed"
        exit 1
    fi

    echo "Initialization complete."
    echo ""

    # Step 2: Setup persistent storage
    echo "=== Step 2: Setting Up Persistent Storage ==="
    echo "Running: ./storj-up persist db,storagenode,auth"
    ./storj-up persist db,storagenode,auth

    if [ $? -ne 0 ]; then
        echo "Error: storj-up persist failed"
        exit 1
    fi

    echo "Persistent storage configured."
    echo ""

    # Step 3: Configure environment variables with IP address
    echo "=== Step 3: Configuring Environment Variables ==="
    echo ""
    echo "NOTE: These environment variables are REQUIRED for bucket creation"
    echo "      and S3 gateway functionality to work properly."
    echo ""

    echo "Setting satellite-api environment variables..."
    ./storj-up env setenv satellite-api STORJ_CONSOLE_GATEWAY_CREDENTIALS_REQUEST_URL=http://${IP_ADDRESS}:8888
    ./storj-up env setenv satellite-api STORJ_CONSOLE_LINKSHARING_URL=http://${IP_ADDRESS}:9090

    echo "Setting authservice environment variables..."
    ./storj-up env setenv authservice STORJ_ENDPOINT=http://${IP_ADDRESS}:9999

    echo "Setting linksharing environment variables..."
    ./storj-up env setenv linksharing STORJ_PUBLIC_URL=http://${IP_ADDRESS}:9090

    echo ""
    echo "Environment variables configured successfully."
    echo "Bucket creation and S3 gateway features are now enabled."
    echo ""
else
    echo ""
    echo "=== Skipping Initialization Steps ==="
    echo "Using existing Storj-Up installation."
    echo "Only HTTPS configuration will be applied."
    echo ""
fi

# Configure HTTPS for gateway-mt (Step number depends on whether this is a new or existing install)
if [ "$EXISTING_INSTALL" = true ]; then
    echo "=== Step 1: Configuring Gateway-MT HTTPS ==="
else
    echo "=== Step 4: Configuring Gateway-MT HTTPS ==="
fi

# Create certificates directory
CERT_DIR="$SCRIPT_DIR/certificates"
if [ ! -d "$CERT_DIR" ]; then
    mkdir -p "$CERT_DIR"
    echo "Created certificate directory: $CERT_DIR"
fi

# Check for certificate files
CRT_FILES=$(ls "$CERT_DIR"/*.crt 2>/dev/null | wc -l)
KEY_FILES=$(ls "$CERT_DIR"/*.key 2>/dev/null | wc -l)

if [ "$CRT_FILES" -eq 0 ] || [ "$KEY_FILES" -eq 0 ]; then
    echo ""
    echo "WARNING: SSL Certificate files not found!"
    echo ""
    echo "REQUIRED: Place your SSL certificate files in:"
    echo "  $CERT_DIR"
    echo ""
    echo "Required files:"
    echo "  - Certificate: fullchain.crt or server.crt"
    echo "  - Private key: private.key or server.key"
    echo ""
    echo "IMPORTANT: Files MUST have .crt and .key extensions!"
    echo ""
    read -p "Continue without certificates? HTTPS will not work until added. (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Please add certificate files to $CERT_DIR and run this script again."
        exit 1
    fi
else
    echo "Certificate files found:"
    ls -lh "$CERT_DIR"/*.crt "$CERT_DIR"/*.key 2>/dev/null
    echo ""
fi

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"

# Backup the generated docker-compose.yaml
cp "$COMPOSE_FILE" "${COMPOSE_FILE}.before-https-config"
echo "Backed up docker-compose.yaml"
echo ""
echo "Configuring gateway-mt HTTPS..."

# Create Python helper script
cat > "$SCRIPT_DIR/modify_compose.py" << 'EOFPYTHON'
#!/usr/bin/env python3
import sys
import re

def modify_gateway_mt(compose_file, ip_address, cert_dir):
    with open(compose_file, 'r') as f:
        lines = f.readlines()

    result = []
    i = 0

    while i < len(lines):
        line = lines[i]

        # Start of gateway-mt service - rebuild it completely
        if re.match(r'^  gateway-mt:\s*$', line):
            result.append(line)
            i += 1

            # Collect existing sections we want to preserve
            deploy_section = []
            env_vars = {}
            networks_section = []

            # Read through gateway-mt section and skip/capture everything
            in_section = True
            while i < len(lines) and in_section:
                line = lines[i]

                # Check if we've reached the next service (indentation level 2)
                if re.match(r'^  \w', line):
                    in_section = False
                    break

                # Capture deploy section (keep it exactly as is)
                if re.match(r'^    deploy:\s*$', line):
                    deploy_section.append(line)
                    i += 1
                    while i < len(lines) and re.match(r'^      ', lines[i]):
                        deploy_section.append(lines[i])
                        i += 1
                    continue

                # Capture environment variables (we'll rebuild this section)
                if re.match(r'^    environment:\s*$', line):
                    i += 1
                    while i < len(lines) and re.match(r'^      (\S+):', lines[i]):
                        match = re.match(r'^      (\S+): (.*)$', lines[i])
                        if match:
                            env_vars[match.group(1)] = match.group(2)
                        i += 1
                    continue

                # Capture networks section (keep it exactly as is)
                if re.match(r'^    networks:\s*$', line):
                    networks_section.append(line)
                    i += 1
                    while i < len(lines) and re.match(r'^      ', lines[i]):
                        networks_section.append(lines[i])
                        i += 1
                    continue

                # Skip command, ports, volumes sections entirely (we'll recreate them)
                if re.match(r'^    (command|ports|volumes):\s*$', line):
                    i += 1
                    # Skip all content under this section
                    while i < len(lines) and (re.match(r'^      ', lines[i]) or re.match(r'^    - ', lines[i])):
                        i += 1
                    continue

                # Skip standalone image line
                if re.match(r'^    image: ', line):
                    i += 1
                    continue

                # Skip any other properties at the service level (4 spaces indent)
                if re.match(r'^    \S', line):
                    i += 1
                    continue

                i += 1

            # Now write the gateway-mt section in the correct order
            # 1. Deploy
            if deploy_section:
                result.extend(deploy_section)

            # 2. Environment with STORJ_SERVER_ADDRESS first
            result.append('    environment:\n')
            result.append('      STORJ_SERVER_ADDRESS: 0.0.0.0:20010\n')
            for key, value in sorted(env_vars.items()):
                if key != 'STORJ_SERVER_ADDRESS':
                    result.append(f'      {key}: {value}\n')

            # 3. Image
            result.append('    image: img.dev.storj.io/storjup/edge:1.97.0\n')

            # 4. Command
            result.append('    command:\n')
            result.append('    - gateway-mt\n')
            result.append('    - run\n')
            result.append('    - --defaults=dev\n')
            result.append('    - --cert-dir=/certs\n')
            result.append('    - --server.address=0.0.0.0:20010\n')
            result.append('    - --server.address-tls=0.0.0.0:9999\n')
            result.append('    - --insecure-disable-tls=false\n')

            # 5. Ports
            result.append('    ports:\n')
            result.append(f'    - "{ip_address}:9999:9999"\n')
            result.append(f'    - "{ip_address}:20010:20010"\n')

            # 6. Volumes
            result.append('    volumes:\n')
            result.append('    - type: bind\n')
            result.append(f'      source: {cert_dir}\n')
            result.append('      target: /certs\n')
            result.append('      bind:\n')
            result.append('        create_host_path: true\n')

            # 7. Networks
            if networks_section:
                result.extend(networks_section)

            continue

        result.append(line)
        i += 1

    with open(compose_file, 'w') as f:
        f.writelines(result)

if __name__ == '__main__':
    modify_gateway_mt(sys.argv[1], sys.argv[2], sys.argv[3])
EOFPYTHON

# Run the Python script
chmod +x "$SCRIPT_DIR/modify_compose.py"
python3 "$SCRIPT_DIR/modify_compose.py" "$COMPOSE_FILE" "$IP_ADDRESS" "$CERT_DIR"

if [ $? -eq 0 ]; then
    echo "Gateway-MT HTTPS configuration complete."
    rm -f "$SCRIPT_DIR/modify_compose.py"
else
    echo "Error: Failed to modify docker-compose.yaml"
    echo "Please check the backup at: ${COMPOSE_FILE}.before-https-config"
    exit 1
fi

echo ""

# Configure port bindings for other services (Step number depends on whether this is a new or existing install)
if [ "$EXISTING_INSTALL" = true ]; then
    echo "=== Step 2: Configuring Service Port Bindings ==="
else
    echo "=== Step 5: Configuring Service Port Bindings ==="
fi

echo "Configuring service port bindings..."

# Update linksharing port if service exists
if grep -q "^  linksharing:" "$COMPOSE_FILE"; then
    # Use awk to update linksharing ports
    awk -v ip="$IP_ADDRESS" '
    BEGIN { in_linksharing=0; in_ports=0 }
    /^  linksharing:/ { in_linksharing=1 }
    in_linksharing && /^    ports:/ {
        in_ports=1
        print
        print "    - \"" ip ":9090:9090\""
        next
    }
    in_linksharing && in_ports && /^    - / { next }
    in_linksharing && /^  [a-zA-Z]/ && !/^    / {
        in_linksharing=0
        in_ports=0
    }
    { print }
    ' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp" && mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
    echo "  Configured linksharing port: ${IP_ADDRESS}:9090"
fi

# Update authservice port if service exists
if grep -q "^  authservice:" "$COMPOSE_FILE"; then
    # Use awk to update authservice ports
    awk -v ip="$IP_ADDRESS" '
    BEGIN { in_authservice=0; in_ports=0 }
    /^  authservice:/ { in_authservice=1 }
    in_authservice && /^    ports:/ {
        in_ports=1
        print
        print "    - \"" ip ":8888:8888\""
        next
    }
    in_authservice && in_ports && /^    - / { next }
    in_authservice && /^  [a-zA-Z]/ && !/^    / {
        in_authservice=0
        in_ports=0
    }
    { print }
    ' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp" && mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
    echo "  Configured authservice port: ${IP_ADDRESS}:8888"
fi

echo "Service port bindings configured."

echo ""

# Start services (Step number depends on whether this is a new or existing install)
if [ "$EXISTING_INSTALL" = true ]; then
    echo "=== Step 3: Restarting Services ==="
else
    echo "=== Step 6: Starting Services ==="
fi
echo ""

if [ "$EXISTING_INSTALL" = true ]; then
    read -p "Restart services to apply changes? (y/n) " -n 1 -r
else
    read -p "Start all services now? (y/n) " -n 1 -r
fi
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Proactively create storage node directories before starting services
    echo "Preparing storage node directories..."
    for i in {1..10}; do
        NODE_DIR="$SCRIPT_DIR/storagenode${i}"

        # Create base directory
        if [ ! -d "$NODE_DIR" ]; then
            mkdir -p "$NODE_DIR"
        fi

        # Create required subdirectories for storagenode identity and storage
        mkdir -p "$NODE_DIR/.local/share/storj/identity/storagenode"
        mkdir -p "$NODE_DIR/storj/storage/blobs"
        mkdir -p "$NODE_DIR/storj/storage/trash"
        mkdir -p "$NODE_DIR/storj/storage/temp"

        # Set proper permissions (777 to avoid permission issues in containers)
        chmod -R 777 "$NODE_DIR" 2>/dev/null || true
    done
    echo "Storage node directories prepared."
    echo ""

    if [ "$EXISTING_INSTALL" = true ]; then
        echo "Restarting services with docker compose..."
        docker compose down
        docker compose up -d
    else
        echo "Starting services with docker compose..."
        docker compose up -d
    fi

    echo ""
    echo "Services started. Checking status..."
    sleep 3
    docker compose ps

    # Monitor storage nodes for startup issues
    echo ""
    echo "=== Monitoring Storage Node Startup ==="
    echo "Checking for storage node failures (waiting 15 seconds)..."
    sleep 15

    # Check if any storage nodes have exited
    FAILED_NODES=$(docker compose ps --format json | grep storagenode | grep -i "exited" || true)

    if [ -n "$FAILED_NODES" ]; then
        echo ""
        echo "WARNING: Some storage nodes failed to start."
        echo "Checking logs for permission errors..."

        # Check logs for permission/directory errors
        PERMISSION_ERRORS=$(docker compose logs 2>&1 | grep -i "storagenode" | grep -iE "permission denied|cannot create directory|no such file or directory|mkdir|file exists" || true)

        if [ -n "$PERMISSION_ERRORS" ]; then
            echo ""
            echo "DETECTED: Storage node directory/permission errors"
            echo ""
            echo "Attempting automatic fix..."
            echo ""

            # Stop services first
            docker compose down

            # Fix storage node directories
            echo "Creating and fixing storage node directories..."
            for i in {1..10}; do
                NODE_DIR="$SCRIPT_DIR/storagenode${i}"
                if [ ! -d "$NODE_DIR" ]; then
                    mkdir -p "$NODE_DIR"
                    echo "  Created: $NODE_DIR"
                fi

                # Create required subdirectories with proper structure
                mkdir -p "$NODE_DIR/.local/share/storj/identity/storagenode"
                mkdir -p "$NODE_DIR/storj/storage/blobs"
                mkdir -p "$NODE_DIR/storj/storage/trash"
                mkdir -p "$NODE_DIR/storj/storage/temp"

                # Set proper permissions (777 to avoid permission issues in containers)
                chmod -R 777 "$NODE_DIR" 2>/dev/null || true

                echo "  Fixed: storagenode${i}"
            done

            echo ""
            echo "Directory structure created. Restarting services..."
            docker compose up -d

            echo ""
            echo "Waiting for storage nodes to initialize..."
            sleep 10

            # Check status again
            echo ""
            echo "Final status check:"
            docker compose ps

            echo ""
            STILL_FAILED=$(docker compose ps --format json | grep storagenode | grep -i "exited" || true)
            if [ -n "$STILL_FAILED" ]; then
                echo "WARNING: Some storage nodes are still failing."
                echo "Check logs with: docker compose logs storagenode1"
            else
                echo "SUCCESS: All storage nodes appear to be running."
            fi
        else
            echo ""
            echo "Storage nodes failed but no permission errors detected."
            echo "Check logs with: docker compose logs | grep storagenode"
        fi
    else
        echo "All storage nodes started successfully!"
    fi
else
    if [ "$EXISTING_INSTALL" = true ]; then
        echo "Skipping service restart."
        echo ""
        echo "To restart services later, run:"
        echo "  cd $SCRIPT_DIR"
        echo "  docker compose restart"
    else
        echo "Skipping service startup."
        echo ""
        echo "To start services later, run:"
        echo "  cd $SCRIPT_DIR"
        echo "  docker compose up -d"
    fi
fi

echo ""
echo "=========================================="
if [ "$EXISTING_INSTALL" = true ]; then
    echo "HTTPS Configuration Applied!"
else
    echo "Storj-Up Setup Complete!"
fi
echo "=========================================="
echo ""
echo "Installation Directory: $SCRIPT_DIR"
echo "Certificate Directory: $CERT_DIR"
echo ""
echo "============================================"
echo "PRIMARY ACCESS URLS:"
echo "============================================"
echo ""
echo "  Web UI:        http://${IP_ADDRESS}:10000"
echo "  S3 Gateway:    https://${IP_ADDRESS}:9999"
echo ""
echo "============================================"
echo ""
echo "Additional Service Endpoints:"
echo "  Gateway-MT HTTP:  http://${IP_ADDRESS}:20010"
echo "  Linksharing:      http://${IP_ADDRESS}:9090"
echo "  Authservice:      http://${IP_ADDRESS}:8888"
echo ""
echo "Certificate Requirements:"
echo "  Location: $CERT_DIR"
echo "  Files needed:"
echo "    - *.crt (certificate file)"
echo "    - *.key (private key file)"
echo "  IMPORTANT: Must use .crt and .key extensions!"
echo ""
echo "Useful Commands:"
echo "  cd $SCRIPT_DIR"
echo "  docker compose ps                    # List services"
echo "  docker compose logs -f               # Follow all logs"
echo "  docker compose logs -f gateway-mt    # Follow specific service"
echo "  docker compose restart <service>     # Restart a service"
echo "  docker compose down                  # Stop all services"
echo "  docker compose up -d                 # Start all services"
echo ""
echo "Storj-Up Commands:"
echo "  ./storj-up env list                  # List all environment variables"
echo "  ./storj-up env setenv <service> <var>=<value>  # Set environment variable"
echo "  ./storj-up persist <services>        # Make storage persistent"
echo ""
echo "Storage Node Notes:"
echo "  - 10 storage nodes will be created automatically"
echo "  - They may take 30-60 seconds to fully initialize"
echo "  - Check logs: docker compose logs -f | grep storagenode"
echo ""
echo "If you encounter issues:"
echo "  1. Verify certificates are in: $CERT_DIR"
echo "  2. Check firewall allows ports: 10000, 9999, 20010, 9090, 8888"
echo "  3. Verify IP address $IP_ADDRESS is accessible"
echo "  4. Check logs: docker compose logs -f"
echo ""
echo "Next Steps:"
echo "  1. Access Web UI at: http://${IP_ADDRESS}:10000"
echo "  2. Create an account and project"
echo "  3. Generate S3 credentials in the Web UI"
echo "  4. Configure your S3 client with endpoint: https://${IP_ADDRESS}:9999"
echo ""
echo "Configuration backup: ${COMPOSE_FILE}.before-https-config"
