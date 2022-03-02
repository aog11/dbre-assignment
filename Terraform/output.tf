output "machine_name" {
  value = google_compute_instance.pgsql_vm[*].name
}

output "machine_private_ip" {
  value = google_compute_instance.pgsql_vm[*].network_interface.0.network_ip
}

output "machine_public_ip" {
  value = google_compute_instance.pgsql_vm[*].network_interface.0.access_config.0.nat_ip
}

output "bucket_url" {
  value = google_storage_bucket.postgres_backup_bucket.url
}