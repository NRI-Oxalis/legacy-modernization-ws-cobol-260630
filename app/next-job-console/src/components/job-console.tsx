"use client";

import { useEffect, useMemo, useState } from "react";
import type { Run, Unit, UnitListResponse, UnitRunListResponse } from "@/lib/types";

type RunsByUnit = Record<string, Run[]>;
type BusyByUnit = Record<string, boolean>;
type ErrorByUnit = Record<string, string | null>;

function formatDate(raw: string | null): string {
  if (!raw) {
    return "-";
  }
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) {
    return raw;
  }
  return date.toLocaleString("ja-JP");
}

function statusClass(status: string | null): string {
  const value = (status || "").toLowerCase();
  if (value.includes("succeeded") || value.includes("success")) {
    return "pill pill-ok";
  }
  if (value.includes("failed") || value.includes("error")) {
    return "pill pill-error";
  }
  if (value.includes("running") || value.includes("inprogress")) {
    return "pill pill-running";
  }
  return "pill";
}

export default function JobConsole() {
  const [units, setUnits] = useState<Unit[]>([]);
  const [runsByUnit, setRunsByUnit] = useState<RunsByUnit>({});
  const [loadingUnits, setLoadingUnits] = useState<boolean>(true);
  const [busyByUnit, setBusyByUnit] = useState<BusyByUnit>({});
  const [errorByUnit, setErrorByUnit] = useState<ErrorByUnit>({});
  const [globalError, setGlobalError] = useState<string | null>(null);

  const sortedUnits = useMemo(
    () => [...units].sort((a, b) => a.unitName.localeCompare(b.unitName)),
    [units],
  );

  async function loadUnits() {
    setLoadingUnits(true);
    setGlobalError(null);
    try {
      const response = await fetch("/api/units", { cache: "no-store" });
      const payload = (await response.json()) as UnitListResponse | { error?: string; details?: string };
      if (!response.ok || !("units" in payload)) {
        throw new Error(payload.error || payload.details || "Failed to load units");
      }
      setUnits(payload.units);
    } catch (error) {
      setGlobalError(error instanceof Error ? error.message : "Unknown error");
    } finally {
      setLoadingUnits(false);
    }
  }

  async function loadRuns(unitName: string) {
    setErrorByUnit((prev) => ({ ...prev, [unitName]: null }));
    try {
      const response = await fetch(`/api/units/${encodeURIComponent(unitName)}/runs`, {
        cache: "no-store",
      });
      const payload = (await response.json()) as UnitRunListResponse | { error?: string; details?: string };
      if (!response.ok || !("runs" in payload)) {
        throw new Error(payload.error || payload.details || "Failed to load runs");
      }
      setRunsByUnit((prev) => ({ ...prev, [unitName]: payload.runs }));
    } catch (error) {
      setErrorByUnit((prev) => ({
        ...prev,
        [unitName]: error instanceof Error ? error.message : "Unknown error",
      }));
    }
  }

  async function triggerRun(unitName: string) {
    setBusyByUnit((prev) => ({ ...prev, [unitName]: true }));
    setErrorByUnit((prev) => ({ ...prev, [unitName]: null }));
    try {
      const response = await fetch(`/api/units/${encodeURIComponent(unitName)}/runs`, {
        method: "POST",
      });
      const payload = (await response.json()) as { error?: string; details?: string };
      if (!response.ok) {
        throw new Error(payload.error || payload.details || "Failed to start job");
      }
      await loadRuns(unitName);
    } catch (error) {
      setErrorByUnit((prev) => ({
        ...prev,
        [unitName]: error instanceof Error ? error.message : "Unknown error",
      }));
    } finally {
      setBusyByUnit((prev) => ({ ...prev, [unitName]: false }));
    }
  }

  useEffect(() => {
    void loadUnits();
  }, []);

  useEffect(() => {
    if (units.length === 0) {
      return;
    }
    units.forEach((unit) => {
      void loadRuns(unit.unitName);
    });
  }, [units]);

  return (
    <main className="page-wrap">
      <section className="hero">
        <h1>Practice Bank Job Console</h1>
        <p>
          Flask API ラッパー経由で ACA Job を起動します。各ユニットの Run ボタンでジョブ実行し、直近の実行履歴を確認できます。
        </p>
        <div className="hero-actions">
          <button type="button" onClick={() => void loadUnits()} disabled={loadingUnits}>
            {loadingUnits ? "Loading..." : "ユニット一覧を再取得"}
          </button>
        </div>
        {globalError && <p className="error-text">{globalError}</p>}
      </section>

      <section className="grid">
        {sortedUnits.map((unit) => {
          const runs = runsByUnit[unit.unitName] || [];
          const busy = busyByUnit[unit.unitName] || false;
          const error = errorByUnit[unit.unitName];

          return (
            <article key={unit.unitName} className="card">
              <header className="card-header">
                <div>
                  <h2>{unit.unitName}</h2>
                  <p>{unit.description}</p>
                </div>
                <span className="job-name">{unit.jobName}</span>
              </header>

              <p className="source">source: {unit.source}</p>

              <div className="actions">
                <button type="button" onClick={() => void triggerRun(unit.unitName)} disabled={busy}>
                  {busy ? "Starting..." : "Run"}
                </button>
                <button type="button" className="secondary" onClick={() => void loadRuns(unit.unitName)} disabled={busy}>
                  Refresh Runs
                </button>
              </div>

              {error && <p className="error-text">{error}</p>}

              <div className="run-list">
                {runs.length === 0 ? (
                  <p className="empty">実行履歴がありません</p>
                ) : (
                  runs.slice(0, 6).map((run) => (
                    <div key={run.name} className="run-row">
                      <div className="run-main">
                        <strong>{run.name}</strong>
                        <span className={statusClass(run.status)}>{run.status || "Unknown"}</span>
                      </div>
                      <div className="run-time">
                        <span>Start: {formatDate(run.startTime)}</span>
                        <span>End: {formatDate(run.endTime)}</span>
                      </div>
                    </div>
                  ))
                )}
              </div>
            </article>
          );
        })}
      </section>
    </main>
  );
}
