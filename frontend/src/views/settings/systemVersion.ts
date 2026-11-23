export function hasFrontendVersionMismatch(backendCommit: string | null | undefined, frontendCommit: string): boolean {
  const backend = (backendCommit ?? '').trim()
  const frontend = frontendCommit.trim()
  if (!backend || !frontend || backend === 'unknown' || frontend === 'unknown') return false
  return !backend.startsWith(frontend)
}
