import { proxyGet, proxyPost } from "@/lib/flask-proxy";
import { NextRequest } from "next/server";

type Context = {
  params: {
    unitName: string;
  };
};

export async function GET(_req: NextRequest, context: Context) {
  const unitName = encodeURIComponent(context.params.unitName);
  return proxyGet(`/units/${unitName}/runs`);
}

export async function POST(req: NextRequest, context: Context) {
  const unitName = encodeURIComponent(context.params.unitName);
  return proxyPost(`/units/${unitName}/runs`, req);
}
