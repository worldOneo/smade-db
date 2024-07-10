wget https://github.com/RedisLabs/memtier_benchmark/releases/download/2.0.0/memtier-benchmark_2.0.0.jammy_amd64.deb
wget https://github.com/dragonflydb/dragonfly/releases/download/v1.11.0/dragonfly_amd64.deb
apt update
apt install libevent-2.1-7 libevent-core-2.1-7 libevent-openssl-2.1-7 -y
dpkg -i ./memtier-benchmark_2.0.0.jammy_amd64.deb
dpkg -i ./dragonfly_amd64.deb
wget https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz
tar -xf zig-linux-x86_64-0.13.0.tar.xz
git clone https://github.com/worldOneo/smade-db
cd smade-db
../zig-linux-x86_64-0.13.0/zig build-exe -O ReleaseFast -mcpu native ./src/main.zig
../zig-linux-x86_64-0.13.0/zig build-exe -O ReleaseFast -mcpu native ./src/loader.zig

service dragonfly stop

cd ..
chown -R $SUDO_USER:$SUDO_USER .
apt install redis-server -y