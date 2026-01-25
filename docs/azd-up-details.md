# How `azd up` Provisions Azure Resources and Deploys Your Application

## Overview of `azd up` Workflow

When you run `azd up`, the Azure Developer CLI executes a 4-phase workflow:

1. **Package** - Build and prepare services
2. **Provision** - Create Azure infrastructure using Bicep templates
3. **Deploy** - Deploy application code to the provisioned resources
4. **Post-Deployment Hooks** - Run configuration and data ingestion scripts

---

## Phase 1: Package (azd package)

### What Happens
Builds the frontend and backend code for deployment.

### For This Project

- **Backend**: Python/Quart application packaged as a Docker image for Azure Container Apps
- **Frontend**: React app built with Vite and bundled into the backend's static files
- **Trigger**: Runs the `prebuild` hook defined in [azure.yaml](../azure.yaml#L31-L38) for Container Apps

### Hook Configuration

```yaml
prebuild:
  posix:
    shell: sh
    run: cd ../frontend;npm install;npm run build  # Build React frontend
```

This ensures that:
1. Frontend dependencies are installed with `npm install`
2. React app is built with `npm run build` (produces optimized bundle)
3. Built frontend is integrated into the Docker image

---

## Phase 2: Provision (azd provision)

### What Happens
Reads [infra/main.bicep](../infra/main.bicep) and creates all Azure resources.

### Key Configuration Files

- **[infra/main.bicep](../infra/main.bicep)** - Main Bicep template (1507 lines)
- **[infra/main.parameters.json](../infra/main.parameters.json)** - Default parameter values
  - Defines default values for all Bicep parameters
  - Can be overridden by `azd env` variables

### Main Bicep Template Structure

The [infra/main.bicep](../infra/main.bicep#L1) is organized as follows:

#### A. Target Scope & Parameters (Lines 1-400)

```bicep
targetScope = 'subscription'
```

- Creates resources at subscription level
- Allows direct resource group creation

**Key Parameters:**
- `environmentName` - Used to generate unique resource names (e.g., "vt46bp34tskcg")
- `location` - Azure region for deployment (validated against allowed regions)
- `tenant()` - Current Azure tenant information

#### B. Core Services Created

##### 1. Resource Group

```bicep
resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}
```

All resources are grouped together for easy management and cleanup.

##### 2. Azure OpenAI Service (Lines 500+)

```bicep
resource openAi 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openAiServiceName
  location: openAiLocation
  kind: 'OpenAI'
  sku: { name: 'S0' }
}
```

**Deployments Created:**
- `gpt-4.1-mini` - Chat model (30 capacity)
  - Used for conversational AI and query responses
  - Version: 2025-04-14
  
- `text-embedding-3-large` - Embedding model (200 capacity)
  - Generates vector embeddings for document chunks
  - 3072-dimensional vectors
  
- `eval` - Evaluation model (30 capacity)
  - Used for evaluating response quality
  
- `knowledgebase` - Knowledge base model (100 capacity)
  - Powers agentic retrieval features

##### 3. Azure AI Search (Lines 600+)

```bicep
resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchServiceName
  location: location
  sku: { name: searchServiceSkuName }  // 'standard' in your case
}
```

**Capabilities:**
- Provides vector search and hybrid search capabilities
- Stores and indexes documents with embeddings
- Supports semantic ranking
- Index name: `gptkbindex` (configurable)

**Search Index Fields:**
- Document content
- Vector embeddings (from text-embedding-3-large)
- Metadata (source, page number, etc.)

##### 4. Azure Storage Account (Lines 700+)

```bicep
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-06-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
}
```

**Purpose:**
- Stores uploaded documents and blobs
- Default container name: `content`
- Provides blob storage for original documents

**Lifecycle:**
- Documents uploaded during `prepdocs.py` ingestion
- Referenced in search results for document retrieval

##### 5. Document Intelligence Service (Lines 800+)

```bicep
resource documentIntelligence 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  kind: 'FormRecognizer'
  location: location
}
```

**Purpose:**
- Extracts text from PDFs
- Recognizes tables and structured content
- Powers the `pdfparser.py` module

**Supported File Types:**
- PDF documents
- TIFF images
- PNG/JPG images
- DOCX files

##### 6. Application Insights & Log Analytics (Lines 900+)

```bicep
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-12-01-preview' = {
  name: logAnalyticsName
  location: location
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  dependsOn: [logAnalyticsWorkspace]
}
```

**Purpose:**
- Monitors application performance and health
- Stores logs and metrics from Container App
- Provides dashboards and alerts

**Data Collected:**
- HTTP requests and responses
- Exception traces
- Custom telemetry from Python backend
- Performance metrics (CPU, memory, etc.)

##### 7. Azure Container Apps (Lines 1000+)

```bicep
resource containerApp 'Microsoft.App/containerApps@2023-05-02' = {
  name: backendServiceName
  location: location
  properties: {
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
      }
    }
    template: {
      containers: [{
        image: 'image-reference'
        env: envVars  // Passes connection strings, API keys
      }]
    }
  }
}
```

**Configuration:**
- Hosts the Python/Quart backend
- Exposes HTTP endpoint on port 8000
- Configured with environment variables for Azure service connections
- Uses managed identity for authentication to other Azure services

**Environment Variables Injected:**
- Service endpoints (Search, OpenAI, Storage)
- API keys (if configured)
- Feature flags (authentication, cloud ingestion, etc.)
- Deployment configuration

#### C. Variable Injection via appEnvVariables (Lines 1350+)

The Bicep template creates a JSON array with all environment variables:

```bicep
var appEnvVariables = [
  { name: 'AZURE_SEARCH_SERVICE', value: searchService.properties.endpoint }
  { name: 'AZURE_SEARCH_INDEX', value: searchIndexName }
  { name: 'AZURE_OPENAI_ENDPOINT', value: openAi.properties.endpoint }
  { name: 'AZURE_OPENAI_CHATGPT_MODEL', value: chatGpt.deploymentName }
  { name: 'AZURE_STORAGE_ACCOUNT', value: storageAccount.name }
  { name: 'AZURE_DOCUMENT_INTELLIGENCE_ENDPOINT', value: documentIntelligence.properties.endpoint }
  { name: 'OPENAI_API_VERSION', value: '2024-08-01-preview' }
  { name: 'EMBEDDING_DEPLOYMENT_NAME', value: embedding.deploymentName }
  // ... many more environment variables
]
```

**Purpose:**
- These variables are passed to the Container App
- Enable the Python backend to connect to all Azure services
- Configured at runtime from Bicep outputs

---

## Phase 3: Deploy (azd deploy)

### What Happens
Pushes the built Docker image to the Container App created in Phase 2.

### Process

1. **Docker Image Build** (during `azd package`)
   - Frontend files built and copied into backend Docker image
   - Python dependencies from `requirements.txt` installed
   - Image tagged with unique identifier

2. **Image Push** (during `azd deploy`)
   - Image uploaded to Azure Container Registry (ACR)
   - Container App updated with new image reference

3. **Container Start**
   - Container starts and listens on port 8000
   - Imports environment variables from Bicep provisioning
   - Python application initializes and awaits requests

**Result:**
- Application is live and accessible via the Container App's public endpoint
- Example: `https://capps-backend-vt46bp34tskcg.greenocean-90aa293d.eastus.azurecontainerapps.io/`

---

## Phase 4: Post-Deployment Hooks

### Defined in [azure.yaml](../azure.yaml#L79-L95)

```yaml
hooks:
  postprovision:
    posix:
      run: ./scripts/auth_update.sh;./scripts/prepdocs.sh
  postdeploy:
    posix:
      run: ./scripts/setup_cloud_ingestion.sh
```

### A. auth_update.sh - Setup Authentication (if enabled)

**File:** [scripts/auth_update.sh](../scripts/auth_update.sh)

**Triggered When:**
- `AZURE_USE_AUTHENTICATION=true` environment variable is set

**What It Does:**
- Runs [scripts/auth_init.py](../scripts/auth_init.py) to configure Microsoft Entra ID (Azure AD)
- Sets up role-based access control (RBAC) if `AZURE_ENFORCE_ACCESS_CONTROL=true`
- Validates configuration requirements

**Example from [scripts/auth_init.sh](../scripts/auth_init.sh#L1-20):**

```bash
#!/bin/sh

echo "Checking if authentication should be setup..."

AZURE_USE_AUTHENTICATION=$(azd env get-value AZURE_USE_AUTHENTICATION)
AZURE_ENABLE_GLOBAL_DOCUMENT_ACCESS=$(azd env get-value AZURE_ENABLE_GLOBAL_DOCUMENT_ACCESS)
AZURE_ENFORCE_ACCESS_CONTROL=$(azd env get-value AZURE_ENFORCE_ACCESS_CONTROL)

if [ "$AZURE_USE_AUTHENTICATION" != "true" ]; then
  echo "AZURE_USE_AUTHENTICATION is not set, skipping authentication setup."
  exit 0
fi

echo "AZURE_USE_AUTHENTICATION is set, proceeding with authentication setup..."

. ./scripts/load_python_env.sh

./.venv/bin/python ./scripts/auth_init.py
```

**Configuration Details:**
- Registers application in Azure Entra ID
- Creates app registration for frontend and backend
- Sets up OAuth 2.0 flows
- Configures permissions and scopes

### B. prepdocs.sh - Document Ingestion

**File:** [scripts/prepdocs.sh](../scripts/prepdocs.sh)

**Execution:**
```bash
#!/bin/sh

USE_CLOUD_INGESTION=$(azd env get-value USE_CLOUD_INGESTION)
if [ "$USE_CLOUD_INGESTION" = "true" ]; then
  echo "Cloud ingestion is enabled, so we are not running the manual ingestion process."
  exit 0
fi

. ./scripts/load_python_env.sh

echo 'Running "prepdocs.py"'

additionalArgs=""
if [ $# -gt 0 ]; then
  additionalArgs="$@"
fi

./.venv/bin/python ./app/backend/prepdocs.py './data/*' --verbose $additionalArgs
```

**Flow:**

1. **Checks for Cloud Ingestion Mode**
   - If `USE_CLOUD_INGESTION=true`, skips local ingestion
   - Azure Functions handle document processing instead

2. **Creates Python Virtual Environment**
   - Sets up isolated Python environment with dependencies
   - Installs requirements from `app/backend/requirements.txt`

3. **Runs Document Ingestion Script**
   - Executes [app/backend/prepdocs.py](../app/backend/prepdocs.py)
   - Processes all files in `./data/*` folder

### What prepdocs.py Does

#### Step 1: Read Documents
- Scans `./data/*` for all file types (PDF, DOCX, JSON, Markdown, etc.)
- File types handled:
  - PDFs (via Azure Document Intelligence)
  - Images (TIFF, PNG, JPG)
  - HTML files
  - CSV/JSON files
  - Markdown text files

#### Step 2: Extract Text
- **For PDFs:** Uses Azure Document Intelligence service
- **For Images:** Extracts text via OCR
- **For Markdown/Text:** Direct text parsing
- Preserves document structure (headings, tables, etc.)

#### Step 3: Split into Chunks
- Uses `textsplitter.py` module
- Splits long documents into overlapping chunks (e.g., 1024 tokens)
- Maintains context with overlap (e.g., 128 tokens between chunks)
- Preserves metadata (source document, page number, section)

#### Step 4: Generate Embeddings
- Uses Azure OpenAI `text-embedding-3-large` model
- Generates 3072-dimensional vector embeddings
- Batch processes chunks (e.g., 16 chunks per batch)
- Reduces cost by batching

#### Step 5: Upload to Search Index
- Uploads chunks with embeddings to Azure AI Search
- Index: `gptkbindex`
- Fields:
  - `content` - Chunk text
  - `embedding3` - Vector embeddings
  - `metadata` - Source, page, section info
  - `source_file` - Original document filename

#### Step 6: Upload Documents to Blob Storage
- Uploads original documents to Azure Storage
- Container: `content`
- Enables document retrieval and citation

**Example Output from Ingestion:**

```
[19:00:03] INFO     Loading azd env from /Users/Jerry.Li/ai-project/azure-search-openai-demo/.azure/demo/.env
           INFO     Connecting to Azure services using the azd credential for tenant ece2aecb-c381-4293-810a-619c0a61fda7
           INFO     Using local files: ./data/*
           
[19:00:05] INFO     Creating new search index gptkbindex
           INFO     Including embedding3 field for text vectors in new index
[19:00:07] INFO     Uploading blob for document 'Zava_Company_Overview.md'
           INFO     Ingesting 'Zava_Company_Overview.md'
           INFO     Splitting 'Zava_Company_Overview.md' into sections
[19:00:09] INFO     Computed embeddings in batch. Batch size: 3, Token count: 518
           INFO     Uploading batch 1 with 3 sections to search index 'gptkbindex'

[19:00:11] INFO     Uploading blob for document 'Northwind_Standard_Benefits_Details.pdf'
           INFO     Ingesting 'Northwind_Standard_Benefits_Details.pdf'
           INFO     Extracting text from './data/Northwind_Standard_Benefits_Details.pdf' using Azure Document Intelligence
[19:00:26] INFO     Splitting 'Northwind_Standard_Benefits_Details.pdf' into sections
[19:00:27] INFO     Computed embeddings in batch. Batch size: 16, Token count: 2497
           INFO     Uploading batch 1 with 305 sections to search index 'gptkbindex'
```

### C. setup_cloud_ingestion.sh - Cloud Ingestion Setup (Optional)

**File:** [scripts/setup_cloud_ingestion.sh](../scripts/setup_cloud_ingestion.sh)

**Triggered When:**
- `USE_CLOUD_INGESTION=true` and Azure Functions are enabled

**What It Does:**
- Configures Azure Functions for serverless document processing
- Sets up event-driven pipelines for continuous ingestion
- Enables automatic processing of new documents

---

## Environment Variables & Configuration

### Storage Location
**`./.azure/<environment-name>/.env`**

Example: `./.azure/demo/.env`

### Variables Set During Provisioning

```bash
AZURE_ENV_NAME=demo
AZURE_LOCATION=eastus
AZURE_SUBSCRIPTION_ID=f940107a-449e-4509-b593-c340dfe0e8e3
AZURE_RESOURCE_GROUP=rg-azure-search-openai-demo-demo
AZURE_RESOURCE_GROUP_ID=/subscriptions/f940107a.../resourceGroups/rg-azure-search-openai-demo-demo

# Azure OpenAI
AZURE_OPENAI_ENDPOINT=https://<service>.openai.azure.com
AZURE_OPENAI_KEY=<key>
AZURE_OPENAI_CHATGPT_MODEL=gpt-4.1-mini
AZURE_OPENAI_CHATGPT_DEPLOYMENT=gpt-4.1-mini
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-large
OPENAI_API_VERSION=2024-08-01-preview

# Azure AI Search
AZURE_SEARCH_SERVICE=https://gptkb-<hash>.search.windows.net
AZURE_SEARCH_SERVICE_KEY=<key>
AZURE_SEARCH_INDEX=gptkbindex

# Azure Storage
AZURE_STORAGE_ACCOUNT=st<hash>
AZURE_STORAGE_CONTAINER=content
AZURE_STORAGE_KEY=<key>

# Document Intelligence
AZURE_DOCUMENT_INTELLIGENCE_ENDPOINT=https://<region>.api.cognitive.microsoft.com
AZURE_DOCUMENT_INTELLIGENCE_KEY=<key>

# Authentication (if enabled)
AZURE_USE_AUTHENTICATION=false
AZURE_ENFORCE_ACCESS_CONTROL=false
AZURE_ENABLE_GLOBAL_DOCUMENT_ACCESS=false
```

### Variable Lifecycle

1. **Set by azd** during provisioning (from Bicep outputs)
   - Bicep outputs contain service endpoints and connection details
   - `azd` captures these outputs automatically

2. **Stored in .env file** by azd CLI
   - Persisted locally for subsequent commands
   - Not committed to version control (in `.gitignore`)

3. **Retrieved by scripts** using `azd env get-value <VAR_NAME>`
   ```bash
   SEARCH_ENDPOINT=$(azd env get-value AZURE_SEARCH_SERVICE)
   ```

4. **Injected into Container App** as environment variables
   - Bicep passes `appEnvVariables` to Container App resource
   - Available to Python application at runtime

5. **Used by Python backend** to connect to Azure services
   ```python
   from azure.search.documents.aio import SearchClient
   search_client = SearchClient(
       endpoint=os.getenv("AZURE_SEARCH_SERVICE"),
       index_name=os.getenv("AZURE_SEARCH_INDEX"),
       credential=azure_credential
   )
   ```

---

## Bicep Template Modular Structure

### File Organization

```
infra/
├── main.bicep                          # Main orchestration file (1507 lines)
├── main.parameters.json                # Default parameters
├── main.test.bicep                     # Test template for CI/CD
├── bicepconfig.json                    # Bicep linter configuration
├── app/
│   ├── backend.bicep                   # Container App resource
│   ├── functions-app.bicep             # Azure Functions (cloud ingestion)
│   ├── app-insights.bicep              # Monitoring resources
│   ├── network-isolation.bicep         # Private endpoint configuration
│   └── functions-rbac.bicep            # RBAC for Functions
└── core/
    ├── storage/                        # Storage account modules
    ├── search/                         # AI Search modules
    ├── open-ai/                        # OpenAI service modules
    ├── monitoring/                     # Application Insights/Log Analytics
    ├── key-vault/                      # Key Vault for secrets
    ├── network/                        # Virtual networks, subnets
    ├── app-service/                    # App Service plan
    └── container-apps/                 # Container Apps environment
```

### Module Dependencies

Each module handles a specific Azure service:
- **storage/** - Azure Storage Account and containers
- **search/** - Azure AI Search with indexes and skillsets
- **open-ai/** - Azure OpenAI Service with deployments
- **monitoring/** - Application Insights and Log Analytics
- **app-service/** - App Service Plan for resource allocation

**Module Usage in main.bicep:**

```bicep
module storageAccount 'core/storage/storage-account.bicep' = {
  name: 'storageAccount'
  scope: resourceGroup
  params: {
    location: location
    storageName: storageAccountName
    containers: [storageContainerName]
  }
}

module searchService 'core/search/search-service.bicep' = {
  name: 'searchService'
  scope: resourceGroup
  params: {
    location: location
    searchName: searchServiceName
    sku: searchServiceSkuName
  }
}
```

### Benefits of Modular Structure

1. **Reusability** - Modules can be used across projects
2. **Maintainability** - Changes isolated to specific modules
3. **Testability** - Each module independently tested
4. **Versioning** - Modules versioned separately
5. **Readability** - main.bicep stays focused on orchestration

---

## How to Perform Post-Deployment Configuration

### 1. Modify azure.yaml Hooks

```yaml
hooks:
  postprovision:
    windows:
      shell: pwsh
      run: ./scripts/auth_update.ps1;./scripts/prepdocs.ps1;./scripts/custom_setup.ps1
      interactive: true
      continueOnError: false
    posix:
      shell: sh
      run: ./scripts/auth_update.sh;./scripts/prepdocs.sh;./scripts/custom_setup.sh
      interactive: true
      continueOnError: false
```

### 2. Create Custom Configuration Scripts

**Example: scripts/custom_setup.sh**

```bash
#!/bin/bash

set -e

echo "Running custom post-deployment configuration..."

# Access provisioned resources
SEARCH_ENDPOINT=$(azd env get-value AZURE_SEARCH_SERVICE)
OPENAI_ENDPOINT=$(azd env get-value AZURE_OPENAI_ENDPOINT)
STORAGE_ACCOUNT=$(azd env get-value AZURE_STORAGE_ACCOUNT)

echo "Search Service: $SEARCH_ENDPOINT"
echo "OpenAI Endpoint: $OPENAI_ENDPOINT"

# Load Python environment
. ./scripts/load_python_env.sh

# Run custom Python setup script
./.venv/bin/python ./scripts/configure_search_synonyms.py
./.venv/bin/python ./scripts/setup_custom_analyzers.py

echo "Custom configuration completed."
```

### 3. Redeploy with Changes

```bash
# Option A: Re-run provisioning (if infrastructure changes needed)
azd provision

# Option B: Just redeploy code (if only application changes)
azd deploy

# Option C: Full update (provision + deploy + hooks)
azd up
```

### 4. Update Bicep Parameters

Edit [infra/main.parameters.json](../infra/main.parameters.json):

```json
{
  "environmentName": {
    "value": "demo"
  },
  "location": {
    "value": "eastus"
  },
  "searchServiceSkuName": {
    "value": "standard"  // Change to 'premium' for higher capacity
  },
  "useAuthentication": {
    "value": false  // Set to true to enable authentication
  }
}
```

Then redeploy:
```bash
azd provision
azd deploy
```

### 5. Update Environment Variables

Add new environment variable to Bicep:

**In infra/main.bicep:**
```bicep
param customFeatureEnabled bool = false

var appEnvVariables = [
  // ... existing variables
  { name: 'CUSTOM_FEATURE_ENABLED', value: string(customFeatureEnabled) }
]
```

**In infra/main.parameters.json:**
```json
{
  "customFeatureEnabled": {
    "value": true
  }
}
```

**In azure.yaml** (for local development):
```yaml
services:
  backend:
    env:
      CUSTOM_FEATURE_ENABLED: "true"
```

---

## Key Takeaways

| Phase | What | Template/Script |
|-------|------|-----------------|
| **Package** | Build Docker image | `azure.yaml` prebuild hook |
| **Provision** | Create Azure resources | `infra/main.bicep` + parameters |
| **Deploy** | Push Docker image to Container App | Azure Container Registry |
| **Post-Provision** | Configure authentication | `scripts/auth_update.sh` |
| **Post-Provision** | Ingest documents | `scripts/prepdocs.sh` |
| **Post-Deployment** | Setup cloud ingestion (optional) | `scripts/setup_cloud_ingestion.sh` |

### Important Notes

1. **Infrastructure as Code (IaC)**
   - All infrastructure defined in Bicep
   - Reproducible and versionable
   - Easy to maintain and scale

2. **Environment Isolation**
   - Each `azd` environment is separate
   - Multiple environments can coexist (dev, staging, prod)
   - Managed via `.azure/<environment-name>/.env`

3. **Authentication**
   - Uses Azure AD/Entra ID when enabled
   - Managed identity for Container App to Azure services
   - No hardcoded credentials in code

4. **Cost Management**
   - `azd down` removes all resources
   - Prevents unintended billing
   - Clean environment teardown

5. **Scaling**
   - Container Apps auto-scale based on CPU/memory
   - Search Service capacity (SKU) adjustable
   - Azure OpenAI quota management through deployments

---

## References

- [Azure Developer CLI Documentation](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/)
- [Bicep Documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
- [Azure Container Apps Documentation](https://learn.microsoft.com/en-us/azure/container-apps/)
- [Azure OpenAI Service Documentation](https://learn.microsoft.com/en-us/azure/ai-services/openai/)
- [Azure AI Search Documentation](https://learn.microsoft.com/en-us/azure/search/)
