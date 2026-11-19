//! The Send-to form for hosts without a JS layer (the phones): fields from a tool's
//! schema, prefill from a Lore item, and form values back to tool arguments. Same
//! rules as `ui/web/src/lib/mcpClient.js`; the prefill only ever uses what the person
//! sees on the item (docs/MCP-Client.md threat model).

use serde::Serialize;
use serde_json::{json, Map, Value};

use super::Tool;

/// What a Lore item offers for prefill.
#[derive(Debug, Default, Clone, serde::Deserialize)]
pub struct Item {
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub detail: String,
    #[serde(default)]
    pub from: String,
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub domain: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Field {
    pub key: String,
    pub label: String,
    pub description: String,
    /// string | number | integer | boolean | enum | json
    pub kind: &'static str,
    pub options: Vec<String>,
    pub required: bool,
}

/// One tool, ready for the form: every value is a string so hosts can bind it to a text field.
#[derive(Debug, Clone, Serialize)]
pub struct Draft {
    pub name: String,
    pub description: String,
    pub fields: Vec<Field>,
    pub values: Map<String, Value>,
}

const HINT_LIMIT: usize = 160;
const TITLE_KEYS: &[&str] = &["title", "name", "summary", "subject"];
const BODY_KEYS: &[&str] = &["description", "body", "content", "text", "notes", "note", "message", "details"];

fn clip(s: &str) -> String {
    if s.chars().count() <= HINT_LIMIT { s.to_string() } else { format!("{}…", s.chars().take(HINT_LIMIT).collect::<String>()) }
}

pub fn schema_fields(schema: &Value) -> Vec<Field> {
    let required: Vec<&str> = schema.get("required").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    let mut fields: Vec<Field> = schema
        .get("properties")
        .and_then(Value::as_object)
        .map(|props| {
            props
                .iter()
                .map(|(key, p)| {
                    let options: Vec<String> = p.get("enum").and_then(Value::as_array).map(|a| a.iter().map(|v| v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string())).collect()).unwrap_or_default();
                    let kind = if !options.is_empty() {
                        "enum"
                    } else {
                        match p.get("type").and_then(Value::as_str) {
                            Some("string") => "string",
                            Some("number") => "number",
                            Some("integer") => "integer",
                            Some("boolean") => "boolean",
                            _ => "json",
                        }
                    };
                    Field {
                        key: key.clone(),
                        label: clip(p.get("title").and_then(Value::as_str).unwrap_or(key)),
                        description: clip(p.get("description").and_then(Value::as_str).unwrap_or("")),
                        kind,
                        options,
                        required: required.contains(&key.as_str()),
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    fields.sort_by_key(|f| !f.required);
    fields
}

fn source_line(it: &Item) -> String {
    let who = if !it.from.is_empty() { &it.from } else if !it.address.is_empty() { &it.address } else { "unknown sender" };
    let subject = if it.subject.is_empty() { "(no subject)" } else { &it.subject };
    format!("From inbox2: {who} — {subject}")
}

fn body(it: &Item) -> String {
    if it.detail.is_empty() { source_line(it) } else { format!("{}\n\n{}", it.detail, source_line(it)) }
}

fn host_of(url: &str) -> String {
    url::Url::parse(url).ok().and_then(|u| u.host_str().map(str::to_lowercase)).unwrap_or_default()
}

/// The hand-written template for a known tool, as candidate values.
fn template(url: &str, tool: &str, it: &Item) -> Option<Value> {
    let host = host_of(url);
    let t = tool.to_lowercase();
    let create_issue = t.contains("create_issue") || t.contains("createissue") || t.contains("save_issue") || t.contains("saveissue");
    if host.ends_with("linear.app") && create_issue {
        return Some(json!({ "title": it.subject, "description": body(it) }));
    }
    if host.contains("github") && t.contains("create_issue") {
        return Some(json!({ "title": it.subject, "body": body(it) }));
    }
    if host.contains("atlassian") && t.contains("jira") && t.contains("create") && t.contains("issue") {
        return Some(json!({ "summary": it.subject, "description": body(it), "issueTypeName": "Task" }));
    }
    if host.contains("hubspot") && t.contains("contact") {
        let mut parts = it.from.split_whitespace();
        let first = parts.next().unwrap_or("").to_string();
        let last = parts.collect::<Vec<_>>().join(" ");
        let props = json!({ "email": it.address, "firstname": first, "lastname": last, "company": it.domain });
        let mut v = props.clone();
        v["properties"] = props;
        return Some(v);
    }
    if host.contains("hubspot") && t.contains("note") {
        return Some(json!({ "body": body(it), "hs_note_body": body(it), "properties": { "hs_note_body": body(it) } }));
    }
    if host.contains("notion") && t.contains("create") && t.contains("page") {
        return Some(json!({
            "pages": [{ "properties": { "title": it.subject }, "content": body(it) }],
            "title": it.subject, "content": body(it),
        }));
    }
    None
}

/// Tools that create something (and known templates) first.
fn score(url: &str, name: &str) -> u8 {
    let t = name.to_lowercase();
    let templated = template(url, name, &Item::default()).is_some();
    u8::from(templated) * 2 + u8::from(["create", "add", "new", "save"].iter().any(|w| t.contains(w)))
}

pub fn drafts(url: &str, tools: Vec<Tool>, item: &Item) -> Vec<Draft> {
    let mut tools = tools;
    tools.sort_by_key(|t| std::cmp::Reverse(score(url, &t.name)));
    tools
        .into_iter()
        .map(|t| {
            let fields = schema_fields(&t.input_schema);
            let cand = template(url, &t.name, item);
            let mut values = Map::new();
            for f in &fields {
                let mut v = cand.as_ref().and_then(|c| c.get(&f.key)).cloned();
                if v.is_none() && cand.is_none() {
                    let k = f.key.to_lowercase();
                    if TITLE_KEYS.contains(&k.as_str()) {
                        v = Some(json!(item.subject));
                    } else if BODY_KEYS.contains(&k.as_str()) {
                        v = Some(json!(body(item)));
                    }
                }
                let text = match v {
                    None | Some(Value::Null) => String::new(),
                    Some(Value::String(s)) => s,
                    Some(other) if f.kind == "json" => serde_json::to_string_pretty(&other).unwrap_or_default(),
                    Some(other) => other.to_string(),
                };
                values.insert(f.key.clone(), Value::String(text));
            }
            Draft { name: t.name, description: clip(&t.description), fields, values }
        })
        .collect()
}

/// Form strings → tool arguments. Empty optionals are dropped; a bad number or JSON
/// field is an error the host shows.
pub fn build_arguments(schema: &Value, values: &Map<String, Value>) -> Result<Value, String> {
    let mut args = Map::new();
    for f in schema_fields(schema) {
        let raw = values.get(&f.key).and_then(Value::as_str).unwrap_or("").trim();
        if f.kind == "boolean" {
            let on = raw.eq_ignore_ascii_case("true");
            if on || f.required {
                args.insert(f.key, Value::Bool(on));
            }
            continue;
        }
        if raw.is_empty() {
            if f.required {
                return Err(format!("{} is required", f.label));
            }
            continue;
        }
        let v = match f.kind {
            "number" => raw.parse::<f64>().ok().and_then(|n| serde_json::Number::from_f64(n)).map(Value::Number).ok_or_else(|| format!("{} must be a number", f.label))?,
            "integer" => raw.parse::<f64>().map(|n| json!(n.trunc() as i64)).map_err(|_| format!("{} must be a number", f.label))?,
            "json" => serde_json::from_str(raw).map_err(|_| format!("{} is not valid JSON", f.label))?,
            _ => Value::String(raw.to_string()),
        };
        args.insert(f.key, v);
    }
    Ok(Value::Object(args))
}

/// The first text block of a tool result, e.g. the new issue's URL. Untrusted: hosts
/// show it as plain text only.
pub fn first_text(content: &Value) -> String {
    content
        .as_array()
        .and_then(|a| a.iter().find(|c| c.get("type").and_then(Value::as_str) == Some("text") && c.get("text").and_then(Value::as_str).is_some_and(|t| !t.is_empty())))
        .and_then(|c| c.get("text").and_then(Value::as_str))
        .unwrap_or("")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(name: &str, schema: Value) -> Tool {
        Tool { name: name.into(), description: "d".into(), input_schema: schema }
    }

    fn item() -> Item {
        Item { subject: "Invoice 42".into(), detail: "Please pay".into(), from: "Ana Li".into(), address: "ana@acme.com".into(), domain: "acme.com".into() }
    }

    fn schema() -> Value {
        json!({ "properties": {
            "title": { "type": "string" }, "description": { "type": "string" }, "priority": { "type": "integer" },
            "urgent": { "type": "boolean" }, "kind": { "enum": ["a", "b"] }, "meta": { "type": "object" },
        }, "required": ["title"] })
    }

    #[test]
    fn prefills_from_the_item_and_ranks_templates_first() {
        let tools = vec![tool("search", schema()), tool("create_issue", schema())];
        let d = drafts("https://mcp.linear.app/mcp", tools, &item());
        assert_eq!(d[0].name, "create_issue");
        assert_eq!(d[0].values["title"], "Invoice 42");
        assert!(d[0].values["description"].as_str().unwrap().contains("From inbox2: Ana Li — Invoice 42"));
        assert_eq!(d[0].fields[0].key, "title", "required first");
    }

    #[test]
    fn unknown_tools_get_guesses_and_arguments_convert() {
        let d = drafts("https://mcp.example.com/", vec![tool("do_thing", schema())], &item());
        assert_eq!(d[0].values["title"], "Invoice 42");
        let mut values = d[0].values.clone();
        values.insert("priority".into(), json!("2"));
        values.insert("urgent".into(), json!("true"));
        values.insert("meta".into(), json!("{\"a\":1}"));
        let args = build_arguments(&schema(), &values).unwrap();
        assert_eq!(args["priority"], 2);
        assert_eq!(args["urgent"], true);
        assert_eq!(args["meta"]["a"], 1);
        assert!(args.get("kind").is_none(), "empty optional dropped");

        values.insert("meta".into(), json!("{oops"));
        assert!(build_arguments(&schema(), &values).unwrap_err().contains("not valid JSON"));
        values.insert("title".into(), json!(""));
        values.insert("meta".into(), json!(""));
        assert!(build_arguments(&schema(), &values).unwrap_err().contains("required"));
    }

    #[test]
    fn first_text_is_the_first_text_block() {
        assert_eq!(first_text(&json!([{"type":"image"},{"type":"text","text":"TUL-1"}])), "TUL-1");
        assert_eq!(first_text(&json!(null)), "");
    }
}
