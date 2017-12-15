output "scheduler-info" {
  value = "${aws_spot_instance_request.dask-scheduler.public_ip}"
}

output "workers-info" {
  value = "${join(",",aws_spot_instance_request.dask-worker.*.public_ip)}"
}

output "scheduler-status" {
  value = "http://${aws_spot_instance_request.dask-scheduler.public_ip}:8787/status"
}
