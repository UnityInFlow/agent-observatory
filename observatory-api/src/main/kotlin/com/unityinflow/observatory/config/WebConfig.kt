package com.unityinflow.observatory.config

import org.springframework.context.annotation.Configuration
import org.springframework.web.servlet.config.annotation.CorsRegistry
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer

/**
 * Only needed when the Vite dev server calls the API cross-origin. Under compose the web
 * container proxies `/api` on the same origin, so no CORS is involved.
 */
@Configuration
class WebConfig(private val properties: ObservatoryProperties) : WebMvcConfigurer {

    override fun addCorsMappings(registry: CorsRegistry) {
        if (properties.corsAllowedOrigins.isEmpty()) return
        registry.addMapping("/api/**")
            .allowedOrigins(*properties.corsAllowedOrigins.toTypedArray())
            .allowedMethods("GET", "POST", "PUT", "DELETE", "OPTIONS")
    }
}
