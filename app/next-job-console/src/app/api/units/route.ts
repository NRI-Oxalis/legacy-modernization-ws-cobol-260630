import { proxyGet } from "@/lib/flask-proxy";

export async function GET() {
  return proxyGet("/units");
}
