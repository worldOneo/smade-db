const fs = require("fs");

const benchmarks = [
  "SET",
  "GET/SET P8 G",
  "GET/SET P1 G",
  "GET/SET P8 R",
  "GET/SET P1 R",
  "SET/GET P1 G",
  "SET/GET P1 R",
  "MULTI SET 5 R",
];

const folder = "./benchmark-results/round-6-intel/";
const results = new Map();

const numFromStr = s => {
  let i = 0;

  while (s.charAt(i) > "9" || s.charAt(i) < "0") {
    i++;
    if (i > s.length) return 1;
  }
  let num = 0;
  while (s.charAt(i) <= "9" && s.charAt(i) >= "0") {
    num *= 10;
    num += s.charCodeAt(i) - "0".charCodeAt(0);
    i++;
  }
  return num;
};

const coreConfigs = [1, 2, 4, 6, 8, 10, 12, 14, 16];
const latencyConfigs = [
  "Avg.",
  "p50",
  "p80",
  "p90",
  "p99",
  "p99.9",
  "p99.99",
  "p99.995",
  "p99.999",
];

/**
 * @type [string, RegExp][]
 */
const databaseConfigs = [
  ["smade", /^smade - \d{1,2}\.txt/],
  ["dragonfly", /^dragonfly - \d{1,2} noaffinity\.txt/],
  ["redis", /^redis\.txt/],
  ["smade - pinned", /^smade - \d{1,2} - 2\.txt/],
  ["dragonfly - pinned", /^dragonfly - \d{1,2}\.txt/],
];

/**
 * @type [string, number, number[]][]
 */
const atilleryStats = fs
  .readdirSync(folder)
  .filter(n => databaseConfigs.findIndex(([_, r]) => r.test(n)) != -1)
  .map(n => [
    n,
    numFromStr(n),
    fs
      .readFileSync(folder + n)
      .toString()
      .split("\n")
      .filter(l => l)
      .map(v => numFromStr(v.split(" ")[1])),
  ]);

for (let benchmark = 0; benchmark < benchmarks.length; benchmark++) {
  const benchResults = new Map();
  for (let c of coreConfigs) {
    let availableCores = c;
    for (let [name, cores, count] of atilleryStats) {
      if (availableCores != cores) continue;

      const dbconfig =
        databaseConfigs[databaseConfigs.findIndex(([_, r]) => r.test(name))][0];

      if (!benchResults.has(dbconfig)) benchResults.set(dbconfig, []);
      // ops, avg, p50, p80, p90, p99, p99.9, p99.99, p99.995, p99.999
      benchResults
        .get(dbconfig)
        .push([
          count[benchmark * 11 + 0],
          count[benchmark * 11 + 1],
          count[benchmark * 11 + 2],
          count[benchmark * 11 + 3],
          count[benchmark * 11 + 4],
          count[benchmark * 11 + 5],
          count[benchmark * 11 + 6],
          count[benchmark * 11 + 7],
          count[benchmark * 11 + 8],
          count[benchmark * 11 + 9],
        ]);
    }
  }
  if (benchResults.size != 0) results.set(benchmarks[benchmark], benchResults);
}

const strs = new Array(12).fill("");
for (let [benchmark, dbs] of results) {
  for (let [conf, cores] of dbs) {
    strs[0] += `${benchmark},,,,,,,,,,,,,,,,,,,,`;
    strs[1] += `${conf},,,,,,,,,,,,,,,,,,,,`;
    strs[2] += `Cores,Ops/Sec,${coreConfigs
      .map(v => `Latency${v}Cores,us`)
      .join(",")},`;
    while (cores.length < coreConfigs.length) {
      cores.push(cores[cores.length - 1]); // adjust for redis
    }
    var i = 3;
    for (let [coreConfig, data] of cores.map((data, i) => [
      coreConfigs[i],
      data,
    ])) {
      strs[i] += `${coreConfig},${data[0]},`;
      i++;
    }
    coreConfigs.forEach((_, n) => {
      i = 3;
      for (let [latency, data] of cores[n]
        .slice(1, 10)
        .map((v, i) => [latencyConfigs[i], v])) {
        strs[i] += `${latency},${data},`;
        i++;
      }
    });
  }
}
console.log(strs.join("\n"));

console.error(`
set terminal pngcairo enhanced font 'Verdana,12' size 900,900
set logscale y
set datafile separator ","
set key left top

set grid xtics ytics mytics
set mytics 10  

set style line 1 lc rgb 'light-blue' lw 5
set style line 2 lc rgb 'blue' lw 5
set style line 3 lc rgb 'red' lw 5
set style line 4 lc rgb 'light-green' lw 5
set style line 5 lc rgb 'dark-green' lw 5

set xtics font "Verdana,18" rotate by -45
set ytics font "Verdana,18"
set rmargin at screen 0.90
set bmargin at screen 0.13

set key font "Verdana,20"
`);

for (let i = 0; i < benchmarks.length; i++) {
  let o = 100 * i;
  console.error(`
set output '${benchmarks[i].replace("/", "-")} Latency.png'
plot \\
  "data.csv" using ${
    20 + o
  }:xticlabels(19) with lp ls 1 pt 1 title "Dragonfly", \\
  "data.csv" using ${
    40 + o
  }:xticlabels(19) with lp ls 2 pt 2 title "Dragonfly aff", \\
  "data.csv" using ${60 + o}:xticlabels(19) with lp ls 3 pt 5 title "Redis", \\
  "data.csv" using ${
    80 + o
  }:xticlabels(19) with lp ls 4 pt 9 title "Smade aff", \\
  "data.csv" using ${100 + o}:xticlabels(19) with lp ls 5 pt 11 title "Smade", 
`);
}

console.error("unset logscale y");

for (let i = 0; i < benchmarks.length; i++) {
  let o = 100 * i;
  console.error(`
set output '${benchmarks[i].replace("/", "-")} Throughput.png'
plot \\
   "data.csv" using ${
     2 + o
   }:xticlabels(1) with lp ls 1 pt 1 title "Dragonfly", \\
   "data.csv" using ${
     22 + o
   }:xticlabels(1) with lp ls 2 pt 2 title "Dragonfly aff", \\
   "data.csv" using ${42 + o}:xticlabels(1) with lp ls 3 pt 5 title "Redis", \\
   "data.csv" using ${
     62 + o
   }:xticlabels(1) with lp ls 4 pt 9 title "Smade aff", \\
   "data.csv" using ${82 + o}:xticlabels(1) with lp ls 5 pt 11 title "Smade", 
`);
}
