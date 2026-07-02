import fs from "node:fs";

const errors = [];
let translatedCount = 0;

for (const [templateFile, translationFile] of [
  ["priv/gettext/default.pot", "priv/gettext/zh_Hans/LC_MESSAGES/default.po"],
  ["priv/gettext/errors.pot", "priv/gettext/zh_Hans/LC_MESSAGES/errors.po"],
]) {
  const templates = parsePo(templateFile);
  const translatedById = new Map(
    parsePo(translationFile).map((entry) => [entry.msgid, entry]),
  );
  for (const template of templates) {
    if (!template.msgid) continue;
    translatedCount += 1;
    const translated = translatedById.get(template.msgid);
    if (!translated) {
      errors.push(
        `${translationFile} 缺少词条：${JSON.stringify(template.msgid)}`,
      );
      continue;
    }
    if (translated.fuzzy) {
      errors.push(
        `${translationFile} 模糊翻译：${JSON.stringify(template.msgid)}`,
      );
    }
    if (
      translated.msgstrs.length === 0 ||
      translated.msgstrs.some((text) => !text.trim())
    ) {
      errors.push(
        `${translationFile} 翻译为空：${JSON.stringify(template.msgid)}`,
      );
    }
  }
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`Validated ${translatedCount} Simplified Chinese UI translations.`);

function parsePo(file) {
  const blocks = fs
    .readFileSync(file, "utf8")
    .replaceAll("\r\n", "\n")
    .split(/\n{2,}/);
  return blocks.map((block) => {
    const lines = block.split("\n");
    const entry = {
      msgid: "",
      msgstrs: [],
      fuzzy: lines.some(
        (line) => line.startsWith("#,") && line.includes("fuzzy"),
      ),
    };
    let target = null;
    for (const line of lines) {
      if (line.startsWith("msgid ")) {
        target = "msgid";
        entry.msgid = decode(line.slice(6));
      } else if (line.startsWith("msgid_plural ")) {
        target = null;
      } else if (/^msgstr(?:\[\d+\])? /.test(line)) {
        target = entry.msgstrs.length;
        entry.msgstrs.push(decode(line.slice(line.indexOf(" ") + 1)));
      } else if (line.startsWith('"')) {
        if (target === "msgid") entry.msgid += decode(line);
        else if (typeof target === "number") {
          entry.msgstrs[target] += decode(line);
        }
      }
    }
    return entry;
  });
}

function decode(quoted) {
  return JSON.parse(quoted);
}
