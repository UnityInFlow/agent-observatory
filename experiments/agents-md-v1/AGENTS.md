# Repository guide

Kotlin + Spring Boot service used as a benchmark fixture.

## Layout

```
sample-service/
├── pom.xml
└── src/
    ├── main/kotlin/com/unityinflow/sample/
    │   ├── SampleServiceApplication.kt
    │   └── customer/            ← the customer feature
    │       ├── Customer.kt              domain model + request DTOs
    │       ├── CustomerRepository.kt    in-memory store
    │       └── CustomerController.kt    REST endpoints under /customers
    └── test/kotlin/com/unityinflow/sample/
        └── customer/CustomerControllerTest.kt
```

## Build and test

Always run from `sample-service/`:

```bash
./mvnw test          # compile + run the test suite
./mvnw -DskipTests package
```

There is no database and no external service — the repository is in-memory, so tests
need no containers and no setup.

## Conventions

- Kotlin, 4-space indent, trailing commas in multi-line parameter lists.
- Request validation belongs at the API boundary, using `jakarta.validation`
  annotations on the request DTO plus `@Valid` on the controller parameter. Spring
  translates a violation into HTTP 400 automatically; do not hand-roll error handling
  for it.
- Controllers stay thin: validate, delegate to the repository, map to a response.
- Tests use `@SpringBootTest` with `@AutoConfigureMockMvc`. On Spring Boot 4 the
  annotation is `org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc`
  — the Boot 3 package no longer exists.
- Add new tests next to the existing ones in the same test class or package.

## Constraints

- Do not add Maven dependencies. Everything needed is already on the classpath,
  including `spring-boot-starter-validation`.
- Keep changes inside the feature you were asked to change. Do not reformat, tidy or
  "improve" unrelated files.
- Do not modify `pom.xml`.

## Definition of done

The task is finished when `./mvnw test` passes from `sample-service/` and the diff
contains only files relevant to the requested change.
