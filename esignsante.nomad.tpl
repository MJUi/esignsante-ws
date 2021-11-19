job "esignsante" {
        datacenters = ["${datacenter}"]
        type = "service"
        vault {
                policies = ["esignsante"]
                change_mode = "noop"
        }

        group "esignsante-servers" {
                count = "1"
                restart {
                        attempts = 3
                        delay = "60s"
                        interval = "1h"
                        mode = "fail"
                }

                network {
                        port "http" { to = 8080 }
                }

                update {
                        max_parallel      = 1
                        canary            = 1
                        min_healthy_time  = "30s"
                        progress_deadline = "5m"
                        healthy_deadline  = "2m"
                        auto_revert       = true
                        auto_promote      = false
                }

                scaling {
                        enabled = true
                        min     = 1
                        max     = 5

						policy {
								# On sélectionne l'instance la moins chargée de toutes les instances en cours,
								# on rajoute une instance (ou on en enlève une) si les seuils spécifiés de requêtes
								# par seconde sont franchis. On pondère le résultat par la consommation de CPU 
								# pour éviter de créer une instance lors du traitement de gros fichiers par esignsante.
                                cooldown = "180s"
                                check "few_requests" {
                                        source = "prometheus"
                                        query = "min(max(http_server_requests_seconds_max{_app='esignsante'}!= 0)by(instance))*max(process_cpu_usage{_app='esignsante'})"
                                        strategy "threshold" {
                                                upper_bound = 1
                                                delta = -1
                                        }
                                }

                                check "many_requests" {
                                        source = "prometheus"
                                        query = "min(max(http_server_requests_seconds_max{_app='esignsante'}!= 0)by(instance))*max(process_cpu_usage{_app='esignsante'})"
                                        strategy "threshold" {
                                                lower_bound = 5
                                                delta = 1
                                        }
                                }
                        }
                }

                task "run" {
                        env {
                                JAVA_TOOL_OPTIONS="-Xms512m -Xmx2g -XX:+UseG1GC -Dspring.config.location=/var/esignsante/application.properties -Dspring.profiles.active=swagger -Dhttp.proxyHost=${proxy_host} -Dhttps.proxyHost=${proxy_host} -Dhttp.proxyPort=${proxy_port} -Dhttps.proxyPort=${proxy_port}"
                        }
                        driver = "docker"
                        config {
                                image = "${artifact.image}:${artifact.tag}"
                                volumes = ["secrets:/var/esignsante"]
                                args = [
                                        "--ws.conf=/var/esignsante/config.json",
                                        "--ws.hashAlgo=BCRYPT",
                                ]
                                ports = ["http"]
                        }
                        template {
data = <<EOH
{
   "signature": [ {{ $length := secrets "esignsante/metadata/signature" | len }}{{ $i := 1 }}{{ range secrets "esignsante/metadata/signature" }}
{{ with secret (printf "esignsante/data/signature/%s" .) }}{{ .Data.data | explodeMap | toJSONPretty | indent 4 }} {{ if lt $i $length }}, {{ end }} {{ end }} {{ $i = add 1 $i }} {{ end }}
  ],
   "proof": [ {{ $length := secrets "esignsante/metadata/proof" | len }}{{ $i := 1 }}{{ range secrets "esignsante/metadata/proof" }}
{{ with secret (printf "esignsante/data/proof/%s" .) }}{{ .Data.data | explodeMap | toJSONPretty | indent 4 }}{{ if lt $i $length }}, {{ end }} {{ end }} {{ $i = add 1 $i }} {{ end }}
  ],
   "signatureVerification": [ {{ $length := secrets "esignsante/metadata/signatureVerification" | len }}{{ $i := 1 }}{{ range secrets "esignsante/metadata/signatureVerification" }}
{{ with secret (printf "esignsante/data/signatureVerification/%s" .) }}{{ .Data.data | explodeMap | toJSONPretty | indent 4 }}{{ if lt $i $length }}, {{ end }} {{ end }} {{ $i = add 1 $i }} {{ end }}
  ],
   "certificateVerification": [ {{ $length := secrets "esignsante/metadata/certificateVerification" | len }}{{ $i := 1 }}{{ range secrets "esignsante/metadata/certificateVerification" }}
{{ with secret (printf "esignsante/data/certificateVerification/%s" .) }}{{ .Data.data | explodeMap | toJSONPretty | indent 4 }}{{ if lt $i $length }}, {{ end }} {{ end }} {{ $i = add 1 $i }} {{ end }}
  ],
   "ca": [ {{ $length := secrets "esignsante/metadata/ca" | len }}{{ $i := 1 }}{{ range secrets "esignsante/metadata/ca" }}
{{ with secret (printf "esignsante/data/ca/%s" .) }}{{ .Data.data | explodeMap | toJSONPretty | indent 4 }}{{ if lt $i $length }}, {{ end }} {{ end }} {{ $i = add 1 $i }} {{ end }}
  ]
}
EOH

                        destination = "secrets/config.json"
                        change_mode = "noop" # noop
                        }
                        template {
data = <<EOF
spring.servlet.multipart.max-file-size=200MB
spring.servlet.multipart.max-request-size=200MB
config.secret=enable

server.servlet.context-path=/esignsante/v1
com.sun.org.apache.xml.internal.security.ignoreLineBreaks=false
management.endpoints.web.exposure.include=prometheus,metrics
EOF
                        destination = "secrets/application.properties"
                        }
                        resources {
                                cpu = 1000
                                memory = 2252
                        }
                        service {
                                name = "$\u007BNOMAD_JOB_NAME\u007D"
                                tags = ["urlprefix-/esignsante/v1/"]
                                canary_tags = ["canary instance to promote"]
                                port = "http"
                                check {
                                        type = "http"
                                        port = "http"
                                        path = "/esignsante/v1"
                                        name = "alive"
                                        interval = "30s"
                                        timeout = "10s"
                                }
                        }
                        service {
                                name = "metrics-exporter"
                                port = "http"
                                tags = ["_endpoint=/esignsante/v1/actuator/prometheus",
                                                                "_app=esignsante",]
                        }
                }
        }
}