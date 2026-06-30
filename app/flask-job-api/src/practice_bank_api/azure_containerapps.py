from __future__ import annotations

from typing import Any

import requests
from azure.identity import DefaultAzureCredential


class ContainerAppJobError(RuntimeError):
    def __init__(self, message: str, status_code: int | None = None, details: Any | None = None):
        super().__init__(message)
        self.status_code = status_code
        self.details = details


class ContainerAppJobsClient:
    def __init__(self, subscription_id: str, resource_group: str, api_version: str):
        self.subscription_id = subscription_id
        self.resource_group = resource_group
        self.api_version = api_version
        self.credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
        self.session = requests.Session()

    def start_job(self, job_name: str) -> dict[str, Any]:
        return self._request("POST", f"{self._job_url(job_name)}/start", json={})

    def list_executions(self, job_name: str) -> list[dict[str, Any]]:
        payload = self._request("GET", f"{self._job_url(job_name)}/executions")
        return [self._compact_execution(item) for item in payload.get("value", [])]

    def get_execution(self, job_name: str, execution_name: str) -> dict[str, Any]:
        payload = self._request("GET", f"{self._job_url(job_name)}/executions/{execution_name}")
        return self._compact_execution(payload)

    def _job_url(self, job_name: str) -> str:
        return (
            "https://management.azure.com"
            f"/subscriptions/{self.subscription_id}"
            f"/resourceGroups/{self.resource_group}"
            f"/providers/Microsoft.App/jobs/{job_name}"
        )

    def _request(self, method: str, url: str, **kwargs: Any) -> dict[str, Any]:
        token = self.credential.get_token("https://management.azure.com/.default")
        headers = kwargs.pop("headers", {})
        headers["Authorization"] = f"Bearer {token.token}"
        headers["Content-Type"] = "application/json"

        response = self.session.request(
            method,
            url,
            params={"api-version": self.api_version},
            headers=headers,
            timeout=30,
            **kwargs,
        )
        if response.status_code >= 400:
            raise ContainerAppJobError(
                "Azure Container Apps request failed",
                status_code=response.status_code,
                details=self._response_payload(response),
            )
        return self._response_payload(response)

    @staticmethod
    def _response_payload(response: requests.Response) -> dict[str, Any]:
        if not response.content:
            return {
                "statusCode": response.status_code,
                "location": response.headers.get("Location"),
                "azureAsyncOperation": response.headers.get("Azure-AsyncOperation"),
            }
        try:
            return response.json()
        except ValueError as exc:
            raise ContainerAppJobError(
                "Azure Container Apps returned a non-JSON response",
                status_code=response.status_code,
                details=response.text,
            ) from exc

    @staticmethod
    def _compact_execution(item: dict[str, Any]) -> dict[str, Any]:
        properties = item.get("properties", {})
        return {
            "name": item.get("name", "").split("/")[-1],
            "status": properties.get("status"),
            "startTime": properties.get("startTime"),
            "endTime": properties.get("endTime"),
            "templateName": properties.get("templateName"),
            "raw": item,
        }