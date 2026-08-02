import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tokensMatch, checkBearerAuth } from '../lib/auth.mjs';

test('tokensMatch: equal tokens match', () => {
  assert.equal(tokensMatch('abc123', 'abc123'), true);
});

test('tokensMatch: different tokens do not match', () => {
  assert.equal(tokensMatch('abc123', 'abc124'), false);
});

test('tokensMatch: different-length tokens do not match', () => {
  assert.equal(tokensMatch('abc', 'abcdef'), false);
});

test('checkBearerAuth: valid bearer header', () => {
  const req = { headers: { authorization: 'Bearer secret-token' } };
  assert.equal(checkBearerAuth(req, 'secret-token'), true);
});

test('checkBearerAuth: missing header rejected', () => {
  const req = { headers: {} };
  assert.equal(checkBearerAuth(req, 'secret-token'), false);
});

test('checkBearerAuth: wrong scheme rejected', () => {
  const req = { headers: { authorization: 'Basic secret-token' } };
  assert.equal(checkBearerAuth(req, 'secret-token'), false);
});

test('checkBearerAuth: wrong token rejected', () => {
  const req = { headers: { authorization: 'Bearer wrong' } };
  assert.equal(checkBearerAuth(req, 'secret-token'), false);
});
