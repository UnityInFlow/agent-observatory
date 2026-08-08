package com.unityinflow.observatory.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "observatory")
data class ObservatoryProperties(
    val grafana: Grafana = Grafana(),
    val corsAllowedOrigins: List<String> = listOf("http://localhost:5173"),
) {
    data class Grafana(
        val baseUrl: String = "http://localhost:3000",
        val tempoDatasourceUid: String = "tempo",
    )
}
