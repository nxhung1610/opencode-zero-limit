import { Resvg } from "@resvg/resvg-js";
import { readFileSync, writeFileSync } from "node:fs";
const [src, out, width] = process.argv.slice(2);
const svg = readFileSync(src, "utf8");
const resvg = new Resvg(svg, {
  fitTo: { mode: "width", value: Number(width) },
  font: { loadSystemFonts: false },
});
writeFileSync(out, resvg.render().asPng());
console.log("wrote", out);
