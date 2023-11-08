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

const folder = "./benchmark-results/round-4-intel/";
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
