cmake_minimum_required (VERSION 3.16)

# Enable Hot Reload for MSVC compilers if supported.
if (POLICY CMP0141)
  cmake_policy(SET CMP0141 NEW)
  set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "$<IF:$<AND:$<C_COMPILER_ID:MSVC>,$<CXX_COMPILER_ID:MSVC>>,$<$<CONFIG:Debug,RelWithDebInfo>:EditAndContinue>,$<$<CONFIG:Debug,RelWithDebInfo>:ProgramDatabase>>")
endif()

project ("RelationalNT")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(RNT_UNITY_BUILD "Enable unity (jumbo) builds for faster compilation" ON)

find_package(unofficial-sqlite3 CONFIG REQUIRED)
find_path(PICOSHA2_INCLUDE_DIRS "picosha2.h")
find_package(Catch2 3 REQUIRED)

add_library(rnt_core OBJECT
    "src/ObjectManager.cpp"
    "src/PermissionsManager.cpp"
    "src/IdentityManager.cpp"
    "src/LifecycleManager.cpp"
    "src/HandlerManager.cpp"
    "src/CursorManager.cpp"
    "src/EphemeralRelation.cpp"
    "src/Merkle.cpp"
    "src/TupleCodec.cpp"
    "src/MultigroupCodec.cpp"
    "src/InMemoryBackend.cpp"
    "src/NamespaceReferenceManager.cpp"
    "src/VM.cpp"
)
target_include_directories(rnt_core PUBLIC "include" ${PICOSHA2_INCLUDE_DIRS})
set_target_properties(rnt_core PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    UNITY_BUILD ${RNT_UNITY_BUILD}
)

add_executable (RelationalNT
    "src/RelationalNT.cpp"
    "src/SqliteBackend.cpp"
)
target_link_libraries(RelationalNT PRIVATE rnt_core unofficial::sqlite3::sqlite3)
target_compile_definitions(RelationalNT PRIVATE NT_CONSOLE_APP)
set_target_properties(RelationalNT PROPERTIES UNITY_BUILD ${RNT_UNITY_BUILD})

enable_testing()

add_executable(RNT_tests
    "test/VM.cpp"
    "test/MultigroupCodec.cpp"
    "test/ObjectManager.cpp"
    "test/NamespaceReferenceManager.cpp"
    "test/LifecycleManager.cpp"
    "test/CursorManager.cpp"
    "test/EphemeralRelation.cpp"
)
target_link_libraries(RNT_tests PRIVATE rnt_core Catch2::Catch2WithMain)
target_compile_definitions(RNT_tests PRIVATE NT_CONSOLE_APP)

set_target_properties(RNT_tests PROPERTIES UNITY_BUILD OFF)

include(Catch)
catch_discover_tests(RNT_tests DISCOVERY_MODE PRE_TEST)

add_library(RNT SHARED
    "src/RNT_C_API.cpp"
    "src/SqliteBackend.cpp"
)
target_link_libraries(RNT PRIVATE rnt_core unofficial::sqlite3::sqlite3)
target_include_directories(RNT PUBLIC "include")
target_compile_definitions(RNT PRIVATE NT_EXPORTS)
set_target_properties(RNT PROPERTIES UNITY_BUILD ${RNT_UNITY_BUILD})

add_executable(RNT_capi_tests
    "test/C_API.cpp"
)
target_link_libraries(RNT_capi_tests PRIVATE RNT Catch2::Catch2WithMain)
catch_discover_tests(RNT_capi_tests DISCOVERY_MODE PRE_TEST)
