const fs = require("fs");

const benchmarks = [
  "SET",
  "GET/SET P8 G",
  "GET/SET P1 G",
  "GET/SET P8 R",
  "GET/SET P1 R",
];

/**
 * @type [string, RegExp][]
 */
const databaseConfigs = [
  ["smade", /^smade - \d{1,2}\.txt/],
  ["smade - pinned", /^smade - \d{1,2} - 2\.txt/],
  ["dragonfly", /^dragonfly - (--num_shards.*|\d{1,2})\.txt/],
  ["dragonfly - unpinned", /^dragonfly - \d{1,2} noaffinity\.txt/],
  ["redis", /^redis\.txt/],
];

const extract =
  /^Totals\s+(?<ops>\d+\.\d{0,})\s+(?<hits>\d+\.\d{0,})\s+(?<misses>\d+\.\d{0,})\s+(?<avg>\d+\.\d{0,})\s+(?<p50>\d+\.\d{0,})\s+(?<p80>\d+\.\d{0,})\s+(?<p90>\d+\.\d{0,})\s+(?<p99>\d+\.\d{0,})\s+(?<p999>\d+\.\d{0,})\s+(?<p9999>\d+\.\d{0,})\s+(?<p99995>\d+\.\d{0,})\s+(?<p99999>\d+\.\d{0,})\s+(?<p100>\d+\.\d{0,})\s+(?<kbps>\d+\.\d{0,})\s{0,}/gm;

const groups = [
  "ops",
  "hits",
  "misses",
  "avg",
  "p50",
  "p80",
  "p90",
  "p99",
  "p99.9",
  "p99.99",
  "p99.995",
  "p99.999",
  "p100",
];

const folder = "./benchmark-results/round-3-intel-full-atillery/";
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

/**
 * @type [string, number, RegExpMatchArray[]][]
 */
const stats = fs
  .readdirSync(folder)
  .filter(n => databaseConfigs.findIndex(([_, r]) => r.test(n)) != -1)
  .map(n => [
    n,
    numFromStr(n),
    Array.from(
      fs
        .readFileSync(folder + n)
        .toString()
        .matchAll(extract)
    ),
  ]);

const coreConfigs = [1, 2, 4, 6, 8, 10, 12, 14, 16];

for (let benchmark = 0; benchmark < benchmarks.length; benchmark++) {
  const benchResults = new Map();
  for (let c of coreConfigs) {
    let availableCores = c;
    for (let [name, cores, count] of stats) {
      if (availableCores != cores) continue;

      const dbconfig =
        databaseConfigs[databaseConfigs.findIndex(([_, r]) => r.test(name))][0];

      if (!benchResults.has(dbconfig)) benchResults.set(dbconfig, []);
      const bench = count[benchmark];
      // ops, avg, p50, p80, p90, p99, p99.9, p99.99, p99.995, p99.999
      benchResults
        .get(dbconfig)
        .push([
          bench[1],
          bench[4],
          bench[5],
          bench[6],
          bench[7],
          bench[8],
          bench[9],
          bench[10],
          bench[11],
          bench[12],
        ]);
    }
  }
  results.set(benchmarks[benchmark], benchResults);
}

/**
 * @type [string, RegExp][]
 */
const atilleryDatabaseConfigs = [
  ["smade", /^atillery smade \d{1,2}\.txt/],
  ["dragonfly", /^atillery dragonfly \d{1,2}\.txt/],
  ["redis", /^atillery redis\.txt/],
  ["smade - pinned", /^atillery smade \d{1,2} - 2\.txt/],
  ["dragonfly - pinned", /^atillery dragonfly \d{1,2} - 2\.txt/],
];

/**
 * @type [string, number, number[]][]
 */
const atilleryStats = fs
  .readdirSync(folder)
  .filter(n => atilleryDatabaseConfigs.findIndex(([_, r]) => r.test(n)) != -1)
  .map(n => [
    n,
    numFromStr(n),
    fs
      .readFileSync(folder + n)
      .toString()
      .split("\n")
      .map(v => numFromStr(v.split(" ")[1])),
  ]);

const benchResults = new Map();
for (let c of coreConfigs) {
  let availableCores = c;
  for (let [name, cores, count] of atilleryStats) {
    if (availableCores != cores) continue;

    const dbconfig =
      atilleryDatabaseConfigs[
        atilleryDatabaseConfigs.findIndex(([_, r]) => r.test(name))
      ][0];

    if (!benchResults.has(dbconfig)) benchResults.set(dbconfig, []);
    // ops, avg, p50, p80, p90, p99, p99.9, p99.99, p99.995, p99.999
    benchResults
      .get(dbconfig)
      .push([
        count[0],
        count[1],
        count[1],
        count[2],
        count[3],
        count[4],
        count[5],
        count[6],
        count[7],
        count[8],
      ]);
  }
}
results.set("atillery", benchResults);

for (let [benchmark, dbs] of results) {
  console.log(benchmark);
  const strs = new Array(11).fill("");
  for (let [conf, cores] of dbs) {
    strs[0] += `${conf},${conf},${conf},${conf},${conf},${conf},${conf},${conf},${conf},${conf},${conf},`;
    strs[1] +=
      "Cores,Ops/Sec,Avg.,p50,p80,p90,p99,p99.9,p99.99,p99.995,p99.999,";
    while (cores.length < coreConfigs.length) {
      cores.push(cores[cores.length - 1]); // adjust for redis
    }
    var i = 2;
    for (let [coreConfig, data] of cores.map((data, i) => [
      coreConfigs[i],
      data,
    ])) {
      strs[i] += `${coreConfig},${data.join(",")},`;
      i++;
    }
  }
  console.log(strs.join("\n"));
}

for (let i = 2; i < 100; i += 12) {
  const a = i;
  const e = i + 10;
  console.error(
    `$data.$B$${a}:$B$${e};$data.$M$${a}:$M$${e};$data.$X$${a}:$X$${e};$data.$AI$${a}:$AI$${e};$data.$AT$${a}:$AT$${e}`
  );
}
