terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "3.5.0"
    }
  }
}

provider "google" {
  project = var.project
  credentials = file(var.credentials_file)
  region = var.region
  zone = var.zone
}

#VPC configuration
resource "google_compute_network" "pgsql_vnet" {
  name = var.vpc_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "pgsql_subnet0" {
  name = var.vpc_subnet_name
  ip_cidr_range = var.vpc_ip_range
  region = var.region
  network = google_compute_network.pgsql_vnet.id
}

#Firewall setup
#Private access between nodes in through ports 22 and 5432
resource "google_compute_firewall" "private_access" {
  name    = "pgsql-private"
  network = google_compute_network.pgsql_vnet.name
  source_ranges = [var.vpc_ip_range]

  allow {
    protocol = "tcp"
    ports    = ["22", "5432"]
  }
}

#Public access to the nodes through port 22
resource "google_compute_firewall" "public_access" {
  name    = "pgsql-public"
  network = google_compute_network.pgsql_vnet.name
  source_ranges = [var.user_public_ip]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

#Disks to be used for postgres data directory
resource "google_compute_disk" "postgres_disk" {
  count = 2
  project = var.project
  name    = "postgres-data-disk-vm${count.index + 1}"
  type    = "pd-ssd"
  zone    = var.zone
  size    = 25
}

#VMs creation, adding user's SSH keys for access
resource "google_compute_instance" "pgsql_vm" {
  count = 2
  name = "${var.machine_name}${count.index + 1}"
  machine_type = "e2-standard-4"
  network_interface {
    network = google_compute_network.pgsql_vnet.name
    subnetwork = google_compute_subnetwork.pgsql_subnet0.name
    access_config {
    }
  }
  boot_disk {
    initialize_params {
      image = var.vm_image_name
    }
  }

  attached_disk {
    source = google_compute_disk.postgres_disk[count.index].self_link
    device_name = "postgres-data-disk0"
    mode = "READ_WRITE"
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_pub_key_file)}"
  }
}

#Google Storage Bucket creation (15 day life for files), using set name for this exercise
resource "google_storage_bucket" "postgres_backup_bucket" {
  project = var.project
  name          = "postgres_backup_bucket11251"
  location      = var.region
  force_destroy = true

  lifecycle_rule {
    condition {
      age = 15
    }
    action {
      type = "Delete"
    }
  }
}

#Owner permission to the service account in the bucket
resource "google_storage_bucket_iam_member" "postgres_backup_bucket_permissions" {
  bucket = google_storage_bucket.postgres_backup_bucket.name
  role = "roles/storage.admin"
  member = "serviceAccount:${var.service_account}"
}

#Alert policies for high disk or CPU usage
resource "google_monitoring_alert_policy" "cpu_usage_alert_policy" {
  display_name = "High CPU Usage"
  combiner = "OR"
  conditions {
    display_name = "High CPU Usage"
    condition_threshold {
      threshold_value = "0.9"
      filter = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\""
      duration = "60s"
      comparison = "COMPARISON_GT"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "disk_usage_alert_policy" {
  display_name = "High Disk Usage"
  combiner = "OR"
  conditions {
    display_name = "High Disk Usage"
    condition_threshold {
      threshold_value = "10"
      filter = "metric.type=\"compute.googleapis.com/guest/disk/bytes_used\" AND resource.type=\"gce_instance\""
      duration = "60s"
      comparison = "COMPARISON_GT"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
}
