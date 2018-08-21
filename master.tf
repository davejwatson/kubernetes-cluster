locals {
  external_ip = "${brightbox_server.k8s_master.ipv4_address_private}"
  fqdn        = "${brightbox_server.k8s_master.fqdn}"
}

resource "brightbox_cloudip" "k8s_master" {
  target = "${brightbox_server.k8s_master.interface}"
  name   = "k8s-master"

  provisioner "local-exec" {
    when    = "destroy"
    command = "ssh-keygen -R ${brightbox_cloudip.k8s_master.fqdn}"
  }

  provisioner "local-exec" {
    when    = "destroy"
    command = "ssh-keygen -R ${brightbox_cloudip.k8s_master.public_ip}"
  }
}

resource "brightbox_server" "k8s_master" {
  count      = "${var.master_count}"
  depends_on = ["brightbox_firewall_policy.k8s"]

  name          = "k8s-master-${count.index}"
  image         = "${data.brightbox_image.k8s_master.id}"
  type          = "${var.master_type}"
  user_data     = "${data.template_file.master-cloud-config.rendered}"
  server_groups = ["${brightbox_server_group.k8s.id}"]

  lifecycle {
    create_before_destroy = true
  }
}

resource "null_resource" "k8s_master" {
  triggers {
    master_id = "${brightbox_server.k8s_master.id}"
  }

  connection {
    user = "${brightbox_server.k8s_master.username}"
    host = "${brightbox_cloudip.k8s_master.fqdn}"
  }

  provisioner "file" {
    source      = "${path.root}/checksums.txt"
    destination = "checksums.txt"
  }

  provisioner "file" {
    content     = "${tls_self_signed_cert.k8s_ca.cert_pem}"
    destination = "ca.crt"
  }

  provisioner "file" {
    content     = "${tls_private_key.k8s_ca.private_key_pem}"
    destination = "ca.key"
  }

  provisioner "file" {
    content     = "${tls_locally_signed_cert.cloud-controller.cert_pem}"
    destination = "cloud-controller.crt"
  }

  provisioner "file" {
    content     = "${tls_private_key.cloud-controller.private_key_pem}"
    destination = "cloud-controller.key"
  }

  provisioner "remote-exec" {
    inline = "${data.template_file.install-provisioner-script.rendered}"
  }

  provisioner "remote-exec" {
    inline = "${data.template_file.master-provisioner-script.rendered}"
  }

  provisioner "remote-exec" {
    when = "destroy"

    # The sleep 10 is a hack to workaround the lack of wait on the delete
    # command
    inline = [
      "kubectl get services -o=jsonpath='{range .items[?(.spec.type==\"LoadBalancer\")]}{\"service/\"}{.metadata.name}{\" \"}{end}' | xargs -r kubectl delete",
      "sleep 10",
    ]
  }
}

data "brightbox_image" "k8s_master" {
  name        = "${var.image_desc}"
  arch        = "x86_64"
  official    = true
  most_recent = true
}

data "template_file" "master-cloud-config" {
  template = "${file("${local.template_path}/master-cloud-config.yml")}"

  vars {
    discovery_url = "${file("${local.generated_path}/discovery${null_resource.etcd_discovery_url.id}")}"
  }
}

data "template_file" "master-provisioner-script" {
  template = "${file("${local.template_path}/install-master")}"

  vars {
    cluster_domainname       = "${var.cluster_domainname}"
    cluster_name             = "${var.cluster_name}"
    hostname                 = "${brightbox_server.k8s_master.hostname}"
    external_ip              = "${local.external_ip}"
    cloud_controller_release = "${var.brightbox_cloud_controller_release}"
    service_cluster_ip_range = "${local.service_cidr}"
    controller_client        = "${var.controller_client}"
    controller_client_secret = "${var.controller_client_secret}"
    apiurl                   = "${local.default_apiurl}"
  }
}

resource "null_resource" "etcd_discovery_url" {
  provisioner "local-exec" {
    command = "[ -d ${local.generated_path} ] || mkdir -p ${local.generated_path} && curl -sSL --retry 3 https://discovery.etcd.io/new?size=${var.worker_count} > ${local.generated_path}/discovery${self.id}"
  }

  provisioner "local-exec" {
    when    = "destroy"
    command = "rm -f ${local.generated_path}/discovery${self.id}"
  }
}

data "template_file" "install-provisioner-script" {
  template = "${file("${local.template_path}/install-kube")}"

  vars {
    critools_release    = "${var.critools_release}"
    cni_plugins_release = "${var.cni_plugins_release}"
    containerd_release  = "${var.containerd_release}"
    runc_release        = "${var.runc_release}"
    cluster_name        = "${var.cluster_name}"
    cluster_domainname  = "${var.cluster_domainname}"
    service_cidr        = "${local.service_cidr}"
    cluster_cidr        = "${local.cluster_cidr}"
    external_ip         = "${local.external_ip}"
    fqdn                = "${local.fqdn}"
    boot_token          = "${local.boot_token}"
  }
}
