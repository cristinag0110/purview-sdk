#!/usr/bin/env python3
"""Envia muestras de texto a las Purview APIs de Microsoft Graph y muestra si hacen match con la DLP.

Lee la configuracion del .env de la raiz del repositorio, autentica con client credentials
(App Registration), y evalua cada linea del fichero de muestras (ignorando comentarios que
empiezan por '#') contra la politica DLP mediante protectionScopes/compute + processContent.

El usuario debe indicarse como object id (GUID). Si solo tienes el UPN, obten su object id con:
    az ad user show --id <UPN> --query id -o tsv

Uso:
    python invoke_purview_dlp_test.py --user <GUID> [--samples-file <ruta>]
    python invoke_purview_dlp_test.py            # solicita los parametros de forma interactiva
"""

from __future__ import annotations

import argparse
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import httpx
from azure.identity import ClientSecretCredential
from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = REPO_ROOT / ".env"
DEFAULT_SAMPLES = REPO_ROOT / "data" / "muestras.txt"

REQUIRED_KEYS = (
    "AZURE_TENANT_ID",
    "PURVIEW_CLIENT_ID",
    "PURVIEW_CLIENT_SECRET",
    "PURVIEW_APP_LOCATION_VALUE",
)


def load_config() -> dict[str, str]:
    if not ENV_PATH.exists():
        sys.exit(f".env no encontrado en: {ENV_PATH}")
    load_dotenv(ENV_PATH)
    cfg = {
        "tenant_id": os.getenv("AZURE_TENANT_ID", ""),
        "client_id": os.getenv("PURVIEW_CLIENT_ID", ""),
        "client_secret": os.getenv("PURVIEW_CLIENT_SECRET", ""),
        "app_name": os.getenv("PURVIEW_APP_NAME", "purview-sdk"),
        "app_version": os.getenv("PURVIEW_APP_VERSION", "1.0"),
        "app_location": os.getenv("PURVIEW_APP_LOCATION_VALUE", ""),
        "graph_base": os.getenv("GRAPH_BASE_URL", "https://graph.microsoft.com/beta").rstrip("/"),
        "scope": os.getenv("GRAPH_SCOPE", "https://graph.microsoft.com/.default"),
    }
    missing = [k for k in REQUIRED_KEYS if not os.getenv(k)]
    if missing:
        sys.exit(f"Faltan variables en .env: {', '.join(missing)}")
    return cfg


def read_samples(path: Path) -> list[str]:
    if not path.exists():
        sys.exit(f"Fichero de muestras no encontrado: {path}")
    lines = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    if not lines:
        sys.exit(f"El fichero de muestras no contiene lineas validas: {path}")
    return lines


def get_token(cfg: dict[str, str]) -> str:
    cred = ClientSecretCredential(cfg["tenant_id"], cfg["client_id"], cfg["client_secret"])
    return cred.get_token(cfg["scope"]).token


def compute_scopes(client: httpx.Client, dsg: str, app_location: str) -> str | None:
    """Llama una vez a protectionScopes/compute y devuelve el ETag (o None)."""
    body = {
        "activities": "uploadText",
        "locations": [
            {"@odata.type": "microsoft.graph.policyLocationApplication", "value": app_location}
        ],
    }
    try:
        resp = client.post(f"{dsg}/protectionScopes/compute", json=body)
        resp.raise_for_status()
        etag = resp.headers.get("ETag")
        scopes = resp.json().get("value", [])
        print(f"  protection scopes devueltos: {len(scopes)} (ETag: {etag})")
        if not scopes:
            print(
                "  AVISO: no se devolvieron protection scopes: puede que ninguna politica aplique "
                "a este usuario+app, o que aun no se haya propagado."
            )
        return etag
    except httpx.HTTPError as exc:
        print(f"  AVISO: protectionScopes/compute fallo: {exc}")
        return None


def build_payload(text: str, cfg: dict[str, str]) -> dict:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    return {
        "contentToProcess": {
            "contentEntries": [
                {
                    "@odata.type": "microsoft.graph.processConversationMetadata",
                    "identifier": str(uuid.uuid4()),
                    "content": {"@odata.type": "microsoft.graph.textContent", "data": text},
                    "name": "purview-sdk Python test",
                    "correlationId": str(uuid.uuid4()),
                    "sequenceNumber": 0,
                    "isTruncated": False,
                    "createdDateTime": now,
                    "modifiedDateTime": now,
                    "contentCategory": "ai",
                }
            ],
            "activityMetadata": {"activity": "uploadText"},
            "protectedAppMetadata": {
                "name": cfg["app_name"],
                "version": cfg["app_version"],
                "applicationLocation": {
                    "@odata.type": "microsoft.graph.policyLocationApplication",
                    "value": cfg["app_location"],
                },
            },
            "integratedAppMetadata": {"name": cfg["app_name"], "version": cfg["app_version"]},
        }
    }


def verdict(policy_actions: list[dict]) -> str:
    if not policy_actions:
        return "NO MATCH"
    parts = []
    for action in policy_actions:
        if action.get("restrictionAction"):
            parts.append(f"MATCH ({action['restrictionAction']})")
        elif action.get("action"):
            parts.append(f"MATCH ({action['action']})")
        else:
            parts.append("MATCH")
    return ", ".join(parts)


def main() -> None:
    parser = argparse.ArgumentParser(description="Prueba de DLP con las Purview APIs de Graph.")
    parser.add_argument("--user", help="Object id (GUID) del usuario de contexto.")
    parser.add_argument("--samples-file", help="Ruta al fichero de muestras.")
    args = parser.parse_args()

    samples_file = args.samples_file
    if not samples_file:
        answer = input(f"Fichero de muestras [{DEFAULT_SAMPLES}]: ").strip()
        samples_file = answer or str(DEFAULT_SAMPLES)

    user = args.user
    if not user:
        user = input("Usuario (object id GUID): ").strip()
    try:
        uuid.UUID(user)
    except (ValueError, TypeError):
        sys.exit(
            f"El usuario debe ser un object id (GUID). Valor recibido: '{user}'. "
            "Obtenlo con: az ad user show --id <UPN> --query id -o tsv"
        )

    cfg = load_config()
    samples = read_samples(Path(samples_file))

    print("Obteniendo token de Microsoft Graph...")
    token = get_token(cfg)
    dsg = f"{cfg['graph_base']}/users/{user}/dataSecurityAndGovernance"
    print(f"Usuario (object id): {user}")

    results: list[tuple[int, str]] = []
    with httpx.Client(headers={"Authorization": f"Bearer {token}"}, timeout=60.0) as client:
        print("Calculando protection scopes...")
        etag = compute_scopes(client, dsg, cfg["app_location"])

        for i, text in enumerate(samples, start=1):
            headers = {"If-None-Match": etag} if etag else {}
            short = text if len(text) <= 60 else text[:60] + "..."
            try:
                resp = client.post(
                    f"{dsg}/processContent", json=build_payload(text, cfg), headers=headers
                )
                resp.raise_for_status()
                v = verdict(resp.json().get("policyActions", []))
                print(f"[{i:2}] {v:<12} | {short}")
                results.append((i, v))
            except httpx.HTTPStatusError as exc:
                status = exc.response.status_code
                if status == 402:
                    print(f"[{i:2}] ERROR 402   | Pay-as-you-go no configurado (Payment Required)")
                else:
                    print(f"[{i:2}] ERROR {status}   | {exc.response.text[:120]}")
                results.append((i, f"ERROR {status}"))
            except httpx.HTTPError as exc:
                print(f"[{i:2}] ERROR       | {exc}")
                results.append((i, "ERROR"))

    match = sum(1 for _, v in results if v.startswith("MATCH"))
    nomatch = sum(1 for _, v in results if v == "NO MATCH")
    errors = sum(1 for _, v in results if v.startswith("ERROR"))
    print("\n===== Resumen =====")
    print(f"Total: {len(results)}  |  MATCH: {match}  |  NO MATCH: {nomatch}  |  ERRORES: {errors}")


if __name__ == "__main__":
    main()
