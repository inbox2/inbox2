import { describe, it, expect } from 'vitest';
import { buildDefaults, buildArguments, missingRequired, serverDomain, firstText, rankTools } from '../mcpClient';

const item = { subject: 'Invoice 42 overdue', detail: 'Pay by Friday.', from: 'Ana de Vries', address: 'ana@odido.nl', domain: 'odido.nl' };
const schema = (properties, required = []) => ({ type: 'object', properties, required });

describe('mcpClient argument builders', () => {
  it('fills a Linear issue from the template, only for keys the schema has', () => {
    const tool = { name: 'create_issue', input_schema: schema({ title: { type: 'string' }, description: { type: 'string' }, team: { type: 'string' } }, ['title', 'team']) };
    const v = buildDefaults('https://mcp.linear.app/mcp', tool, item);
    expect(v.title).toBe('Invoice 42 overdue');
    expect(v.description).toBe('Pay by Friday.\n\nFrom inbox2: Ana de Vries — Invoice 42 overdue');
    expect(v.team).toBe('');
    expect(missingRequired(tool, v).map((f) => f.key)).toEqual(['team']);
  });

  it('guesses title/description for unknown servers and converts types', () => {
    const tool = { name: 'make_ticket', input_schema: schema({
      summary: { type: 'string' }, body: { type: 'string' }, priority: { type: 'integer' }, urgent: { type: 'boolean' },
      kind: { enum: ['bug', 'task'] }, meta: { type: 'object' },
    }) };
    const v = buildDefaults('https://tickets.example.com/mcp', tool, item);
    expect(v.summary).toBe(item.subject);
    expect(v.body).toContain('From inbox2:');
    const args = buildArguments(tool, { ...v, priority: '2', kind: 'bug', meta: '{"a":1}' });
    expect(args).toEqual({ summary: item.subject, body: v.body, priority: 2, kind: 'bug', meta: { a: 1 } });
    expect(() => buildArguments(tool, { ...v, meta: '{nope' })).toThrow(/JSON/);
  });

  it('puts Notion pages in a JSON field', () => {
    const tool = { name: 'notion-create-pages', input_schema: schema({ pages: { type: 'array' } }, ['pages']) };
    const v = buildDefaults('https://mcp.notion.com/mcp', tool, item);
    expect(JSON.parse(v.pages)[0].properties.title).toBe(item.subject);
  });

  it('helpers', () => {
    expect(serverDomain('https://mcp.linear.app/mcp')).toBe('linear.app');
    expect(serverDomain('https://api.githubcopilot.com/mcp/')).toBe('github.com');
    expect(firstText([{ type: 'image' }, { type: 'text', text: 'TUL-412' }])).toBe('TUL-412');
    expect(rankTools('https://mcp.linear.app/mcp', [{ name: 'list_issues' }, { name: 'create_issue' }])[0].name).toBe('create_issue');
  });
});
