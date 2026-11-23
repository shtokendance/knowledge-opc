import assert from 'node:assert/strict'
import test from 'node:test'
import { hasFrontendVersionMismatch } from './systemVersion'

test('matching backend commit and frontend short commit are not a version mismatch', () => {
  assert.equal(hasFrontendVersionMismatch('45857c9105f598b9d25836391bf780e5c1ced17d', '45857c9'), false)
})

test('different backend and frontend commits are a version mismatch', () => {
  assert.equal(hasFrontendVersionMismatch('9d0427786eec470451c819f5f00cbc6a92d87e38', '45857c9'), true)
})

test('unknown or missing commits do not show a version mismatch', () => {
  assert.equal(hasFrontendVersionMismatch('unknown', '45857c9'), false)
  assert.equal(hasFrontendVersionMismatch(undefined, '45857c9'), false)
  assert.equal(hasFrontendVersionMismatch('45857c9105f598b9d25836391bf780e5c1ced17d', 'unknown'), false)
})
