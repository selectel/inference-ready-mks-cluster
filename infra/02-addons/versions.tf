terraform {
  required_version = ">= 1.9.2"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.15.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.33.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

# Kubeconfig, сгенерированный корнем 01-cluster (terraform output -raw kubeconfig_path).
# Провайдеры не могут зависеть от ресурсов в другом root — поэтому путь приходит переменной.
provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}
