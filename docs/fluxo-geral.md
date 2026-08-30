# Fluxo Geral — ToggleMaster (5 Microserviços)

Este documento descreve a ordem de execução, as comunicações entre serviços/clientes, as APIs e os protocolos usados no projeto **ToggleMaster**.

> **Protocolo:** todos os microserviços se comunicam via **HTTP/REST** (JSON).  
> **Não há gRPC** neste projeto.  
> A única comunicação assíncrona é via **AWS SQS** (fila de mensagens) entre `evaluation-service` e `analytics-service`.

---

## Visão dos Serviços

| Ordem de subida | Serviço | Porta | Stack | Papel |
|---|---|---|---|---|
| 1 | `auth-service` | 8001 | Go | Cria e valida chaves de API |
| 2 | `flag-service` | 8002 | Python | CRUD das definições de feature flags |
| 3 | `targeting-service` | 8003 | Python | CRUD das regras de segmentação |
| 4 | `evaluation-service` | 8004 | Go | Hot path: avalia flags para clientes finais |
| 5 | `analytics-service` | 8005 | Python | Worker: consome SQS e grava no DynamoDB |

**Dependências externas:** PostgreSQL (auth, flag, targeting), Redis (evaluation), AWS SQS + DynamoDB (evaluation → analytics).

---

## Ordem de Execução (Startup)

Os serviços devem subir nesta ordem, porque há dependências em cadeia:

```
1. auth-service          → base de autenticação
2. flag-service          → valida chaves no auth-service
3. targeting-service     → valida chaves no auth-service
4. evaluation-service    → chama flag + targeting; publica eventos no SQS
5. analytics-service     → consome a fila SQS e persiste analytics
```

### Passo a passo operacional

1. **Subir o `auth-service`** e criar chaves de API (`MASTER_KEY`).
2. **Subir o `flag-service`** e criar as flags (ex.: `enable-new-dashboard`).
3. **Subir o `targeting-service`** e criar regras (ex.: `PERCENTAGE = 50`).
4. **Subir Redis** e o **`evaluation-service`** (com `SERVICE_API_KEY` válida).
5. **Subir o `analytics-service`** para consumir a fila SQS.

---

## Dois Fluxos Principais

### A) Fluxo de Configuração (Admin / Operador)

Usado para preparar o sistema (criar chaves, flags e regras).

```
Operador
   │
   │  HTTP POST /admin/keys
   ▼
auth-service (8001)
   │
   │  retorna API Key (tm_key_...)
   ▼
Operador
   │
   ├─ HTTP CRUD /flags ──────────► flag-service (8002)
   │                                   │
   │                                   │ HTTP GET /validate
   │                                   ▼
   │                              auth-service (8001)
   │
   └─ HTTP CRUD /rules ──────────► targeting-service (8003)
                                       │
                                       │ HTTP GET /validate
                                       ▼
                                  auth-service (8001)
```

### B) Fluxo de Avaliação (Cliente Final — Hot Path)

Único fluxo que apps/sites devem chamar em runtime.

```
Cliente (app/web)
   │
   │  HTTP GET /evaluate?user_id=...&flag_name=...
   ▼
evaluation-service (8004)
   │
   ├─ 1) Consulta Redis (cache da flag + regra)
   │     ├─ Cache HIT  → avalia localmente
   │     └─ Cache MISS → busca nos serviços (em paralelo):
   │           │
   │           ├─ HTTP GET /flags/{name} ──► flag-service
   │           │                                │
   │           │                                │ HTTP GET /validate
   │           │                                ▼
   │           │                           auth-service
   │           │
   │           └─ HTTP GET /rules/{name} ──► targeting-service
   │                                            │
   │                                            │ HTTP GET /validate
   │                                            ▼
   │                                       auth-service
   │
   ├─ 2) Executa lógica (ex.: PERCENTAGE) e responde true/false
   │
   └─ 3) Publica evento assíncrono ──► AWS SQS
                                            │
                                            ▼
                                   analytics-service (worker)
                                            │
                                            ▼
                                       AWS DynamoDB
```

---

## Comunicações entre Serviços e Clientes

| Origem | Destino | Quando | Protocolo | Autenticação |
|---|---|---|---|---|
| Operador / Admin | `auth-service` | Criar chaves | **HTTP** | `Bearer MASTER_KEY` |
| Operador / Admin | `flag-service` | CRUD de flags | **HTTP** | `Bearer API_KEY` |
| Operador / Admin | `targeting-service` | CRUD de regras | **HTTP** | `Bearer API_KEY` |
| Cliente final | `evaluation-service` | Avaliar flag | **HTTP** | Sem auth na API pública |
| `flag-service` | `auth-service` | Validar API key | **HTTP** | Encaminha `Authorization` |
| `targeting-service` | `auth-service` | Validar API key | **HTTP** | Encaminha `Authorization` |
| `evaluation-service` | `flag-service` | Cache miss | **HTTP** | `Bearer SERVICE_API_KEY` |
| `evaluation-service` | `targeting-service` | Cache miss | **HTTP** | `Bearer SERVICE_API_KEY` |
| `evaluation-service` | Redis | Cache get/set | Redis protocol | — |
| `evaluation-service` | AWS SQS | Após cada avaliação | AWS SDK (SQS) | Credenciais AWS |
| `analytics-service` | AWS SQS | Poll contínuo | AWS SDK (SQS) | Credenciais AWS |
| `analytics-service` | AWS DynamoDB | Persistir evento | AWS SDK (DynamoDB) | Credenciais AWS |

---

## APIs por Serviço

### 1. `auth-service` — `http://localhost:8001`

| Método | Endpoint | Descrição | Auth |
|---|---|---|---|
| `GET` | `/health` | Health check | Não |
| `POST` | `/admin/keys` | Cria nova API key | `Bearer MASTER_KEY` |
| `GET` | `/validate` | Valida API key | `Bearer <api_key>` |

**Protocolo:** HTTP/REST (JSON)

---

### 2. `flag-service` — `http://localhost:8002`

| Método | Endpoint | Descrição | Auth |
|---|---|---|---|
| `GET` | `/health` | Health check | Não |
| `POST` | `/flags` | Cria flag | `Bearer API_KEY` |
| `GET` | `/flags` | Lista flags | `Bearer API_KEY` |
| `GET` | `/flags/{name}` | Busca flag por nome | `Bearer API_KEY` |
| `PUT` | `/flags/{name}` | Atualiza flag | `Bearer API_KEY` |
| `DELETE` | `/flags/{name}` | Remove flag | `Bearer API_KEY` |

**Protocolo:** HTTP/REST (JSON)  
**Dependência:** chama `GET {AUTH_SERVICE_URL}/validate` em toda rota protegida.

---

### 3. `targeting-service` — `http://localhost:8003`

| Método | Endpoint | Descrição | Auth |
|---|---|---|---|
| `GET` | `/health` | Health check | Não |
| `POST` | `/rules` | Cria regra de segmentação | `Bearer API_KEY` |
| `GET` | `/rules/{flag_name}` | Busca regra da flag | `Bearer API_KEY` |
| `PUT` | `/rules/{flag_name}` | Atualiza regra | `Bearer API_KEY` |
| `DELETE` | `/rules/{flag_name}` | Remove regra | `Bearer API_KEY` |

**Protocolo:** HTTP/REST (JSON)  
**Dependência:** chama `GET {AUTH_SERVICE_URL}/validate` em toda rota protegida.

Exemplo de regra:

```json
{
  "flag_name": "enable-new-dashboard",
  "is_enabled": true,
  "rules": {
    "type": "PERCENTAGE",
    "value": 50
  }
}
```

---

### 4. `evaluation-service` — `http://localhost:8004`

| Método | Endpoint | Descrição | Auth |
|---|---|---|---|
| `GET` | `/health` | Health check | Não |
| `GET` | `/evaluate?user_id=...&flag_name=...` | Avalia flag para um usuário | Não (API pública) |

**Protocolo da API:** HTTP/REST (JSON)

Resposta exemplo:

```json
{
  "flag_name": "enable-new-dashboard",
  "user_id": "user-123",
  "result": true
}
```

**Comportamento interno:**

1. Busca `flag_info:{flag_name}` no **Redis** (TTL ~30s).
2. Em cache miss, chama em paralelo:
   - `GET {FLAG_SERVICE_URL}/flags/{flag_name}`
   - `GET {TARGETING_SERVICE_URL}/rules/{flag_name}`
3. Avalia a regra (ex.: hash determinístico + `PERCENTAGE`).
4. Responde ao cliente.
5. Envia evento assíncrono para **AWS SQS** (não bloqueia a resposta).

---

### 5. `analytics-service` — `http://localhost:8005`

| Método | Endpoint | Descrição | Auth |
|---|---|---|---|
| `GET` | `/health` | Health check | Não |

**Protocolo da API pública:** HTTP (apenas health).  
**Trabalho principal:** worker em background — **não** é chamado pelos clientes.

Fluxo do worker:

1. Faz long polling na fila **AWS SQS**.
2. Lê mensagens de evento de avaliação.
3. Grava no **DynamoDB** (`ToggleMasterAnalytics`).
4. Remove a mensagem da fila após sucesso.

Payload esperado da mensagem SQS:

```json
{
  "user_id": "user-123",
  "flag_name": "enable-new-dashboard",
  "result": true,
  "timestamp": "2026-07-26T12:00:00Z"
}
```

---

## Diagrama Resumido (Protocolos)

```
                    [HTTP]
 Operador ─────────────────────► auth-service
    │                               ▲
    │ [HTTP]                        │ [HTTP /validate]
    ├──────────────► flag-service ──┘
    │                               ▲
    │ [HTTP]                        │ [HTTP /validate]
    └──────────────► targeting-service

                    [HTTP /evaluate]
 Cliente final ─────────────────► evaluation-service
                                      │
                         ┌────────────┼────────────┐
                         │            │            │
                      [Redis]     [HTTP]       [HTTP]
                         │      flag-service targeting-service
                         │            │            │
                         │            └──── [HTTP /validate] ────► auth-service
                         │
                         └──── [AWS SQS] ────► analytics-service ────► [DynamoDB]
```

---

## Resumo Final

| Pergunta | Resposta |
|---|---|
| Protocolo entre microserviços? | **HTTP/REST** |
| Existe gRPC? | **Não** |
| Cliente final chama qual serviço? | Apenas `evaluation-service` (`/evaluate`) |
| Quem autentica as APIs internas? | `auth-service` (`/validate`) |
| Comunicação assíncrona? | `evaluation-service` → **SQS** → `analytics-service` |
| Ordem de execução (startup) | auth → flag → targeting → evaluation → analytics |
