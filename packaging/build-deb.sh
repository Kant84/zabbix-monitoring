#!/bin/bash
# Сборка .deb пакета из репозитория
set -e
VERSION="${1:-4.2.0}"
PKG_NAME="zabbix-universal-monitor"
BUILD_DIR="/tmp/${PKG_NAME}-build"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/DEBIAN" "$BUILD_DIR/opt/monitoring"

cp -r configs webhook scripts systemd packaging/DEBIAN/control "$BUILD_DIR/opt/monitoring/" 2>/dev/null || true
cp packaging/DEBIAN/control "$BUILD_DIR/DEBIAN/control"
sed -i "s/^Version:.*/Version: $VERSION/" "$BUILD_DIR/DEBIAN/control"

cat > "$BUILD_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
chmod +x /opt/monitoring/scripts/*.sh
chmod +x /opt/monitoring/webhook/max-webhook-server.py
exit 0
EOF
chmod 755 "$BUILD_DIR/DEBIAN/postinst"

dpkg-deb -b "$BUILD_DIR" "${PKG_NAME}_${VERSION}.deb"
echo "Built: ${PKG_NAME}_${VERSION}.deb"
