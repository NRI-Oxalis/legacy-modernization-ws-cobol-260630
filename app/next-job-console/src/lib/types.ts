export type Unit = {
  unitName: string;
  jobName: string;
  source: string;
  description: string;
};

export type Run = {
  name: string;
  status: string | null;
  startTime: string | null;
  endTime: string | null;
  templateName: string | null;
  raw: unknown;
};

export type UnitListResponse = {
  units: Unit[];
};

export type UnitRunListResponse = {
  unitName: string;
  jobName: string;
  runs: Run[];
};

export type StartUnitResponse = {
  unitName: string;
  jobName: string;
  start: unknown;
};
