package com.unityinflow.observatory

import org.junit.jupiter.api.Test
import org.springframework.boot.test.context.SpringBootTest

@SpringBootTest
class ObservatoryApiApplicationTests : AbstractIntegrationTest() {

    @Test
    fun `context loads and flyway migrations apply`() {
        // Failure here means the JPA mapping disagrees with V1__observatory_baseline.sql,
        // because spring.jpa.hibernate.ddl-auto is `validate`.
    }
}
