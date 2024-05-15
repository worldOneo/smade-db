
# Smade-DB: An analysis of the performance characteristics of different in-memory DB designs.

## Setup

To setup the project Ubuntu Server 22 LTS is recommended, debian has shown some issues with io_uring.

Setup everything with the setup script: 
```
curl https://raw.githubusercontent.com/worldOneo/smade-db/master/setupscript.sh | sudo sh
```

This include:

 - Redis
 - Dragonfly
 - Zig Toolchain
 - Downloading and Compiling this project

## Benchmark

:warning: The benchmark script is configured for a 32 Core 64 Threads machine consuming around 14GB of RAM and takes multiple hours to complete.

To reproduce the benchmark results use:

```
chmod +x ./crusher.sh
./crusher.sh
```

## Charts

To create charts from the resulting files you may use `stattransformerv3.js` to create a script for GNUPLOT and configure it with the correct folder like this:

```
const folder = "./benchmark-results/round-6-intel/";
```

The output is a csv file via stdout and a gnuplot script using that csv file via stderr.
This will provide both latency and throughput charts.