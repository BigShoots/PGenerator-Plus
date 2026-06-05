#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");

const worker = fs.readFileSync("usr/bin/meter_lg_3d_autocal.pl", "utf8");
const webui = fs.readFileSync("usr/share/PGenerator/webui.pm", "utf8");
const helper = fs.readFileSync("usr/sbin/pgenerator-lg", "utf8");

function bodyOf(source, name) {
  const start = source.indexOf(`sub ${name}`);
  assert(start >= 0, `${name} helper should exist`);
  const next = source.indexOf("\nsub ", start + 5);
  return source.slice(start, next >= 0 ? next : source.length);
}

const generationGate = bodyOf(worker, "lg_generation_legacy_neutral_guard_enabled");
assert(
  generationGate.includes('$generation->{"ddc_only_white_balance"}') &&
    generationGate.includes('$generation->{"picture_mode_read_forbidden"}') &&
    generationGate.includes("$year && $year <= 2021") &&
    generationGate.includes("$webos_major && $webos_major <= 6") &&
    generationGate.includes("$series =~ /^[BCGZ]1$/"),
  "3D LUT adjacent-neutral guard should be limited to C1/webOS6/2021-or-older generation data"
);

const model = bodyOf(worker, "model_from_readings");
assert(
  model.includes("my $neutral_neighborhood_identity=neutral_neighborhood_identity_enabled($config);") &&
    model.includes("neutral_neighborhood_identity_enabled => json_bool($neutral_neighborhood_identity)") &&
    model.includes("? \"exact diagonal identity plus adjacent neutral-neighborhood identity after current 1D greyscale path\"") &&
    model.includes(": \"exact diagonal identity after current 1D greyscale path\""),
  "3D LUT model should record whether adjacent neutral-neighborhood protection is enabled"
);

const neutralIdentity = bodyOf(worker, "neutral_identity_output");
assert(
  neutralIdentity.includes('if(!$adjacent)') &&
    neutralIdentity.includes('return undef if(!($r==$g && $g==$b));') &&
    neutralIdentity.includes("return undef if(($max-$min) > 1);"),
  "C2/newer 3D LUT generation should preserve only exact diagonal nodes, while legacy mode preserves adjacent neutral nodes"
);

const cube = bodyOf(worker, "generate_lut_cube");
const payload = bodyOf(worker, "generate_lut_lg_payload");
assert(
  cube.includes("neutral_identity_output($model,$r,$g,$b,$size)") &&
    payload.includes("neutral_identity_output($model,$r,$g,$b,$size)") &&
    !worker.includes("neutral_neighborhood_identity_output("),
  "Cube and LG payload generation should both use the generation-gated neutral identity helper"
);

const reset = bodyOf(worker, "reset_3d_lut_to_unity_before_profile");
assert(
  reset.includes('lg_generation => (ref($config->{"preflight_lg_generation"}) eq "HASH") ? $config->{"preflight_lg_generation"} : undef') &&
    reset.includes('$config->{"lg_generation"}=$reset->{"lg_generation"} if(ref($reset->{"lg_generation"}) eq "HASH");'),
  "3D LUT worker should carry LG generation from preflight or live reset metadata into LUT generation"
);

const exportSource = bodyOf(worker, "export_lut");
assert(
  exportSource.includes('neutral_axis_protection => $model->{"neutral_neighborhood_identity_enabled"}') &&
    exportSource.includes("neutral_neighborhood_identity_enabled => json_bool($model->{\"neutral_neighborhood_identity_enabled\"})") &&
    exportSource.includes('lg_generation => (ref($config->{"lg_generation"}) eq "HASH") ? $config->{"lg_generation"} : undef'),
  "3D LUT exports should expose the active neutral guard mode and generation metadata"
);

assert(
  webui.includes("lg_generation:lutReset.lg_generation||null") &&
    webui.includes("preflight_lg_generation:skipPreprofileUnityReset&&preflightLut3d.lg_generation?preflightLut3d.lg_generation:undefined"),
  "Web UI full workflow should pass preflight LG generation metadata to the 3D LUT worker"
);

const upload = bodyOf(helper, "lg_3d_lut_upload_workflow");
assert(
  upload.includes("lg_generation => $generation") &&
    upload.includes("upload_verified => &json_true()"),
  "LG helper 3D upload/reset response should include generation metadata without changing upload verification"
);

console.log("LG 3D LUT neutral guard generation regression checks passed.");
