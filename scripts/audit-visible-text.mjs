import fs from "node:fs";
import path from "node:path";

const dashboardRoot = path.resolve("grafana/dashboards");
const findings = [];
const allowedEnglishOnly = [
  /^TeslaMate$/,
  /^Grafana$/,
  /^PostgreSQL$/,
  /^OpenStreetMap$/,
  /^WGS-84$/,
  /^GCJ-02$/,
  /^SQL$/,
  /^API$/,
  /^MQTT$/,
  /^Docker$/,
  /^\$[A-Za-z_][\w:{}.\-$]*$/,
  /^(?:k?Wh|kW|km|mi|mph|bar|psi|°[CF]|A|V|ID)$/i,
  /^Wh\/(?:km|mi)$/i,
];

for (const relativeFile of fs.readdirSync(dashboardRoot, { recursive: true })) {
  if (!relativeFile.endsWith(".json")) continue;
  const normalizedFile = relativeFile.replaceAll("\\", "/");
  const dashboard = JSON.parse(
    fs.readFileSync(path.join(dashboardRoot, relativeFile), "utf8"),
  );

  check(normalizedFile, "title", dashboard.title);
  for (const [index, annotation] of (
    dashboard.annotations?.list ?? []
  ).entries()) {
    check(normalizedFile, `annotations.${index}.name`, annotation.name);
  }
  for (const [index, link] of (dashboard.links ?? []).entries()) {
    check(normalizedFile, `links.${index}.title`, link.title);
  }
  for (const [index, variable] of (
    dashboard.templating?.list ?? []
  ).entries()) {
    if (variable.hide === 2) continue;
    check(
      normalizedFile,
      `templating.${index}.label`,
      variable.label ?? variable.name,
    );
    for (const [optionIndex, option] of (variable.options ?? []).entries()) {
      check(
        normalizedFile,
        `templating.${index}.options.${optionIndex}`,
        option.text,
      );
    }
  }
  for (const [index, panel] of (dashboard.panels ?? []).entries()) {
    auditPanel(normalizedFile, panel, `panels.${index}`);
  }
}

for (const finding of findings) console.log(finding);
console.error(
  `Found ${findings.length} visible ${process.argv.includes("--mixed") ? "strings containing English" : "English-only strings"}.`,
);
if (process.argv.includes("--check") && findings.length > 0) process.exit(1);

function auditPanel(file, panel, location) {
  check(file, `${location}.title`, panel.title);
  check(file, `${location}.description`, panel.description);
  for (const [linkIndex, link] of (panel.links ?? []).entries()) {
    check(file, `${location}.links.${linkIndex}.title`, link.title);
  }
  for (const [linkIndex, link] of (
    panel.fieldConfig?.defaults?.links ?? []
  ).entries()) {
    check(
      file,
      `${location}.fieldConfig.defaults.links.${linkIndex}.title`,
      link.title,
    );
  }
  if (panel.type === "text") {
    check(file, `${location}.options.content`, panel.options?.content);
  }
  check(file, `${location}.options.basemap.name`, panel.options?.basemap?.name);
  check(
    file,
    `${location}.fieldConfig.defaults.displayName`,
    panel.fieldConfig?.defaults?.displayName,
  );

  for (const [overrideIndex, override] of (
    panel.fieldConfig?.overrides ?? []
  ).entries()) {
    for (const [propertyIndex, property] of (
      override.properties ?? []
    ).entries()) {
      if (property.id === "displayName") {
        check(
          file,
          `${location}.overrides.${overrideIndex}.properties.${propertyIndex}.displayName`,
          property.value,
        );
      }
      if (property.id === "mappings") {
        auditMappings(
          file,
          property.value,
          `${location}.overrides.${overrideIndex}.properties.${propertyIndex}.mappings`,
        );
      }
      if (property.id === "links") {
        for (const [linkIndex, link] of (property.value ?? []).entries()) {
          check(
            file,
            `${location}.overrides.${overrideIndex}.properties.${propertyIndex}.links.${linkIndex}.title`,
            link.title,
          );
        }
      }
    }
  }
  auditMappings(
    file,
    panel.fieldConfig?.defaults?.mappings,
    `${location}.mappings`,
  );

  for (const [transformationIndex, transformation] of (
    panel.transformations ?? []
  ).entries()) {
    for (const [source, target] of Object.entries(
      transformation.options?.renameByName ?? {},
    )) {
      check(
        file,
        `${location}.transformations.${transformationIndex}.renameByName.${source}`,
        target,
      );
    }
  }
  if (process.argv.includes("--sql-aliases")) {
    const renamedSources = new Set(
      (panel.fieldConfig?.overrides ?? [])
        .filter((override) =>
          (override.properties ?? []).some(({ id }) => id === "displayName"),
        )
        .map((override) => override.matcher?.options)
        .filter((value) => typeof value === "string"),
    );
    for (const transformation of panel.transformations ?? []) {
      for (const source of Object.keys(
        transformation.options?.renameByName ?? {},
      )) {
        renamedSources.add(source);
      }
    }
    for (const [targetIndex, target] of (panel.targets ?? []).entries()) {
      for (const match of (target.rawSql ?? "").matchAll(
        /\bAS\s+"([^"]+)"/gi,
      )) {
        if (!renamedSources.has(match[1])) {
          check(file, `${location}.targets.${targetIndex}.sqlAlias`, match[1]);
        }
      }
    }
  }
  for (const [index, nested] of (panel.panels ?? []).entries()) {
    auditPanel(file, nested, `${location}.panels.${index}`);
  }
}

function auditMappings(file, mappings, location) {
  for (const [mappingIndex, mapping] of (mappings ?? []).entries()) {
    if (mapping.options && typeof mapping.options === "object") {
      for (const [source, result] of Object.entries(mapping.options)) {
        check(file, `${location}.${mappingIndex}.${source}`, result?.text);
      }
    }
  }
}

function check(file, location, value) {
  if (typeof value !== "string") return;
  const plain = value
    .replace(/<[^>]*>/g, " ")
    .replace(/\$\{[^}]+\}/g, " ")
    .trim();
  if (!/[A-Za-z]{2,}/.test(plain)) return;
  if (!process.argv.includes("--mixed") && /[\p{Script=Han}]/u.test(plain)) {
    return;
  }
  if (allowedEnglishOnly.some((pattern) => pattern.test(plain))) return;
  findings.push(`${file}\t${location}\t${JSON.stringify(value)}`);
}
