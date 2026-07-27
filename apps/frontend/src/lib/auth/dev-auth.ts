// Development-only authenticated identity for the Prism frontend loop. The
// NODE_ENV guard makes the bypass impossible in a production Next.js process,
// even if DEV_AUTH_BYPASS is accidentally present in its environment.
export function isDevelopmentAuthEnabled(): boolean {
  return process.env.NODE_ENV === "development" && process.env.DEV_AUTH_BYPASS === "true";
}
