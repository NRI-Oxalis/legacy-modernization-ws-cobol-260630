from __future__ import annotations

import os

from flask import Flask, Response, jsonify, redirect

from practice_bank_api.azure_containerapps import ContainerAppJobError, ContainerAppJobsClient
from practice_bank_api.config import Settings


def create_app() -> Flask:
    settings = Settings.from_env()
    client = ContainerAppJobsClient(
        subscription_id=settings.subscription_id,
        resource_group=settings.resource_group,
        api_version=settings.api_version,
    )

    app = Flask(__name__)
    app.config["SETTINGS"] = settings
    app.config["JOBS_CLIENT"] = client

    @app.get("/healthz")
    def healthz():
        return jsonify({"status": "ok", "allowedJobs": settings.allowed_jobs})

    @app.get("/")
    def index():
        return redirect("/docs", code=302)

    @app.get("/openapi.json")
    def openapi_json():
        return jsonify(_openapi_spec(settings))

    @app.get("/docs")
    def swagger_ui():
        return Response(_swagger_ui_html(), mimetype="text/html")

    @app.post("/jobs/<job_name>/runs")
    def start_job(job_name: str):
        _ensure_allowed_job(settings, job_name)
        result = client.start_job(job_name)
        return jsonify({"jobName": job_name, "start": result}), 202

    @app.get("/jobs/<job_name>/runs")
    def list_runs(job_name: str):
        _ensure_allowed_job(settings, job_name)
        return jsonify({"jobName": job_name, "runs": client.list_executions(job_name)})

    @app.get("/jobs/<job_name>/runs/<execution_name>")
    def get_run(job_name: str, execution_name: str):
        _ensure_allowed_job(settings, job_name)
        return jsonify({"jobName": job_name, "run": client.get_execution(job_name, execution_name)})

    @app.errorhandler(PermissionError)
    def permission_error(error: PermissionError):
        return jsonify({"error": str(error)}), 404

    @app.errorhandler(ContainerAppJobError)
    def container_app_error(error: ContainerAppJobError):
        status_code = error.status_code if error.status_code and error.status_code < 500 else 502
        return jsonify({"error": str(error), "details": error.details}), status_code

    return app


def _ensure_allowed_job(settings: Settings, job_name: str) -> None:
    if job_name not in settings.allowed_jobs:
        raise PermissionError("job is not exposed by this API")


def _openapi_spec(settings: Settings) -> dict:
    return {
        "openapi": "3.0.3",
        "info": {
            "title": "Practice Bank COBOL Job API",
            "version": "0.1.0",
            "description": "Thin Flask wrapper for starting and inspecting existing Azure Container Apps Jobs.",
        },
        "servers": [{"url": "/"}],
        "tags": [
            {"name": "health", "description": "API health checks"},
            {"name": "jobs", "description": "Existing COBOL Azure Container Apps Jobs"},
        ],
        "paths": {
            "/healthz": {
                "get": {
                    "tags": ["health"],
                    "summary": "Check API health and exposed Job names",
                    "responses": {
                        "200": {
                            "description": "API is ready",
                            "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Health"}}},
                        }
                    },
                }
            },
            "/jobs/{jobName}/runs": {
                "get": {
                    "tags": ["jobs"],
                    "summary": "List Job executions",
                    "parameters": [_job_name_parameter(settings)],
                    "responses": {
                        "200": {
                            "description": "Executions returned by Azure Container Apps",
                            "content": {"application/json": {"schema": {"$ref": "#/components/schemas/RunList"}}},
                        },
                        "404": {"description": "Job is not exposed by this API"},
                        "502": {"description": "Azure Container Apps request failed"},
                    },
                },
                "post": {
                    "tags": ["jobs"],
                    "summary": "Start a Job execution",
                    "parameters": [_job_name_parameter(settings)],
                    "responses": {
                        "202": {
                            "description": "Azure accepted the Job start request",
                            "content": {"application/json": {"schema": {"$ref": "#/components/schemas/StartJobResponse"}}},
                        },
                        "404": {"description": "Job is not exposed by this API"},
                        "502": {"description": "Azure Container Apps request failed"},
                    },
                },
            },
            "/jobs/{jobName}/runs/{executionName}": {
                "get": {
                    "tags": ["jobs"],
                    "summary": "Get one Job execution",
                    "parameters": [
                        _job_name_parameter(settings),
                        {
                            "name": "executionName",
                            "in": "path",
                            "required": True,
                            "schema": {"type": "string"},
                            "example": "pb-batch-gesqxil",
                        },
                    ],
                    "responses": {
                        "200": {
                            "description": "Execution returned by Azure Container Apps",
                            "content": {"application/json": {"schema": {"$ref": "#/components/schemas/RunResponse"}}},
                        },
                        "404": {"description": "Job is not exposed by this API"},
                        "502": {"description": "Azure Container Apps request failed"},
                    },
                }
            },
        },
        "components": {
            "schemas": {
                "Health": {
                    "type": "object",
                    "properties": {
                        "status": {"type": "string", "example": "ok"},
                        "allowedJobs": {"type": "array", "items": {"type": "string"}, "example": list(settings.allowed_jobs)},
                    },
                },
                "StartJobResponse": {
                    "type": "object",
                    "properties": {
                        "jobName": {"type": "string", "example": settings.allowed_jobs[0] if settings.allowed_jobs else "pb-batch"},
                        "start": {"type": "object", "additionalProperties": True},
                    },
                },
                "RunList": {
                    "type": "object",
                    "properties": {
                        "jobName": {"type": "string"},
                        "runs": {"type": "array", "items": {"$ref": "#/components/schemas/Run"}},
                    },
                },
                "RunResponse": {
                    "type": "object",
                    "properties": {
                        "jobName": {"type": "string"},
                        "run": {"$ref": "#/components/schemas/Run"},
                    },
                },
                "Run": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "example": "pb-batch-gesqxil"},
                        "status": {"type": "string", "example": "Succeeded"},
                        "startTime": {"type": "string", "format": "date-time", "nullable": True},
                        "endTime": {"type": "string", "format": "date-time", "nullable": True},
                        "templateName": {"type": "string", "nullable": True},
                        "raw": {"type": "object", "additionalProperties": True},
                    },
                },
            }
        },
    }


def _job_name_parameter(settings: Settings) -> dict:
    parameter = {
        "name": "jobName",
        "in": "path",
        "required": True,
        "schema": {"type": "string"},
        "example": settings.allowed_jobs[0] if settings.allowed_jobs else "pb-batch",
    }
    if settings.allowed_jobs:
        parameter["schema"]["enum"] = list(settings.allowed_jobs)
    return parameter


def _swagger_ui_html() -> str:
    return """<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Practice Bank COBOL Job API</title>
    <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
    <script>
      window.ui = SwaggerUIBundle({
        url: '/openapi.json',
        dom_id: '#swagger-ui',
        deepLinking: true,
        displayRequestDuration: true,
        tryItOutEnabled: true
      });
    </script>
  </body>
</html>
"""


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8000"))
    create_app().run(host="0.0.0.0", port=port)