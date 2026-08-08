package com.unityinflow.observatory

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.context.properties.ConfigurationPropertiesScan
import org.springframework.boot.runApplication

@SpringBootApplication
@ConfigurationPropertiesScan
class ObservatoryApiApplication

fun main(args: Array<String>) {
    runApplication<ObservatoryApiApplication>(*args)
}
