import { NextRequest, NextResponse } from "next/server";

const DEFAULT_API_BASE = "http://localhost:8080";

function apiBaseUrl(): string {
  return process.env.FLASK_JOB_API_BASE_URL || DEFAULT_API_BASE;
}

async function requestFlask(
  path: string,
  method: "GET" | "POST",
  body?: unknown,
): Promise<NextResponse> {
  const url = `${apiBaseUrl()}${path}`;
  const response = await fetch(url, {
    method,
    headers: {
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
    cache: "no-store",
  });

  const text = await response.text();
  const isJson = (response.headers.get("content-type") || "").includes("application/json");
  const payload = isJson && text ? JSON.parse(text) : { raw: text };

  return NextResponse.json(payload, { status: response.status });
}

export async function proxyGet(path: string): Promise<NextResponse> {
  try {
    return await requestFlask(path, "GET");
  } catch (error) {
    return NextResponse.json(
      {
        error: "Failed to reach Flask Job API",
        details: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 502 },
    );
  }
}

export async function proxyPost(path: string, req?: NextRequest): Promise<NextResponse> {
  try {
    const body = req ? await req.json().catch(() => ({})) : {};
    return await requestFlask(path, "POST", body);
  } catch (error) {
    return NextResponse.json(
      {
        error: "Failed to reach Flask Job API",
        details: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 502 },
    );
  }
}
