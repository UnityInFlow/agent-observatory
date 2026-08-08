package com.unityinflow.observatory

import org.springframework.test.context.DynamicPropertyRegistry
import org.springframework.test.context.DynamicPropertySource
import org.testcontainers.containers.PostgreSQLContainer
import org.testcontainers.utility.DockerImageName

/**
 * One PostgreSQL container for the whole test suite.
 *
 * Test classes with different context customizers (e.g. MockMvc) get different Spring
 * context cache keys, so a per-context container bean would start — and stop — a database
 * per context. The singleton-container pattern keeps exactly one, shut down explicitly on
 * JVM exit because Testcontainers' Ryuk reaper is disabled in this build.
 *
 * The image is the same version as `infra/compose.yaml`, so migrations and dialect
 * behaviour are exercised against the real thing rather than an in-memory substitute.
 */
abstract class AbstractIntegrationTest {

    companion object {
        @JvmStatic
        private val postgres: PostgreSQLContainer<*> =
            PostgreSQLContainer(DockerImageName.parse("postgres:16.6-alpine")).apply {
                start()
                Runtime.getRuntime().addShutdownHook(Thread { runCatching { stop() } })
            }

        @JvmStatic
        @DynamicPropertySource
        fun datasourceProperties(registry: DynamicPropertyRegistry) {
            registry.add("spring.datasource.url", postgres::getJdbcUrl)
            registry.add("spring.datasource.username", postgres::getUsername)
            registry.add("spring.datasource.password", postgres::getPassword)
        }
    }
}
