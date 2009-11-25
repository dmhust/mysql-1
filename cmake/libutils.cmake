# Copyright (C) 2009 Sun Microsystems, Inc
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA 


# This file exports macros that emulate some functionality found  in GNU libtool
# on Unix systems. One such feature is convenience libraries. In this context,
# convenience library is a static library that can be linked to shared library
# On systems that force position-independent code, linking into shared library
# normally requires compilation with a special flag (often -fPIC). To enable 
# linking static libraries to shared, we compile source files that come into 
# static library with the PIC flag (${CMAKE_SHARED_LIBRARY_C_FLAGS} in CMake)
# Some systems, like Windows or OSX do not need special compilation (Windows 
# never uses PIC and OSX always uses it). 
#
# The intention behind convenience libraries is simplify the build and to reduce
# excessive recompiles.

# Except for convenience libraries, this file provides macros to merge static 
# libraries (we need it for mysqlclient) and to create shared library out of 
# convenience libraries(again, for mysqlclient)

# Following macros are exported
# - ADD_CONVENIENCE_LIBRARY(target source1...sourceN)
# This macro creates convenience library. The functionality is similar to 
# ADD_LIBRARY(target STATIC source1...sourceN), the difference is that resulting 
# library can always be linked to shared library
# 
# - MERGE_LIBRARIES(target [STATIC|SHARED|MODULE]  [linklib1 .... linklibN]
#  [EXPORTS exported_func1 .... exported_func_N]
#  [OUTPUT_NAME output_name]
# This macro merges several static libraries into a single one or creates a shared
# library from several convenience libraries

# Important global flags 
# - WITH_PIC : If set, it is assumed that everything is compiled as position
# independent code (that is CFLAGS/CMAKE_C_FLAGS contain -fPIC or equivalent)
# If defined, ADD_CONVENIENCE_LIBRARY does not add PIC flag to compile flags
#
# - DISABLE_SHARED: If set, it is assumed that shared libraries are not produced
# during the build. ADD_CONVENIENCE_LIBRARY does not add anything to compile flags


GET_FILENAME_COMPONENT(MYSQL_CMAKE_SCRIPT_DIR ${CMAKE_CURRENT_LIST_FILE} PATH)
IF(NOT WIN32 AND NOT CYGWIN AND NOT APPLE AND NOT WITH_PIC AND NOT DISABLE_SHARED 
  AND CMAKE_SHARED_LIBRARY_C_FLAGS)
 SET(_SKIP_PIC 1)
ENDIF()
 
# CREATE_EXPORT_FILE (VAR target api_functions)
# Internal macro, used to create source file for shared libraries that 
# otherwise consists entirely of "convenience" libraries. On Windows, 
# also exports API functions as dllexport. On unix, creates a dummy file 
# that references all exports and this prevents linker from creating an 
# empty library(there are unportable alternatives, --whole-archive)
MACRO(CREATE_EXPORT_FILE VAR TARGET API_FUNCTIONS)
  IF(WIN32)
    SET(DUMMY ${CMAKE_CURRENT_BINARY_DIR}/${TARGET}_dummy.c)
    SET(EXPORTS ${CMAKE_CURRENT_BINARY_DIR}/${TARGET}_exports.def)
    CONFIGURE_FILE_CONTENT("" ${DUMMY})
    SET(CONTENT "EXPORTS\n")
    FOREACH(FUNC ${API_FUNCTIONS})
      SET(CONTENT "${CONTENT} ${FUNC}\n")
    ENDFOREACH()
    CONFIGURE_FILE_CONTENT(${CONTENT} ${EXPORTS})
    SET(${VAR} ${DUMMY} ${EXPORTS})
  ELSE()
    SET(EXPORTS ${CMAKE_CURRENT_BINARY_DIR}/${target}_exports_file.cc)
    SET(CONTENT)
    FOREACH(FUNC ${API_FUNCTIONS})
      SET(CONTENT "${CONTENT} extern void* ${FUNC}\;\n")
    ENDFOREACH()
    SET(CONTENT "${CONTENT} void *${TARGET}_api_funcs[] = {\n")
    FOREACH(FUNC ${API_FUNCTIONS})
     SET(CONTENT "${CONTENT} &${FUNC},\n")
    ENDFOREACH()
    SET(CONTENT "${CONTENT} (void *)0\n}\;")
    CONFIGURE_FILE_CONTENT(${CONTENT} ${EXPORTS})
    SET(${VAR} ${EXPORTS})
  ENDIF()
ENDMACRO()


# MYSQL_ADD_CONVENIENCE_LIBRARY(name source1...sourceN)
# Create static library that can be linked to shared library.
# On systems that force position-independent code, adds -fPIC or 
# equivalent flag to compile flags.
MACRO(ADD_CONVENIENCE_LIBRARY)
  SET(TARGET ${ARGV0})
  SET(SOURCES ${ARGN})
  LIST(REMOVE_AT SOURCES 0)
  ADD_LIBRARY(${TARGET} STATIC ${SOURCES})
  IF(NOT _SKIP_PIC)
    SET_TARGET_PROPERTIES(${TARGET} PROPERTIES  COMPILE_FLAGS
    "${CMAKE_SHARED_LIBRARY_C_FLAGS}")
  ENDIF()
ENDMACRO()


# Handy macro to parse macro arguments
MACRO(CMAKE_PARSE_ARGUMENTS prefix arg_names option_names)
  SET(DEFAULT_ARGS)
  FOREACH(arg_name ${arg_names})    
    SET(${prefix}_${arg_name})
  ENDFOREACH(arg_name)
  FOREACH(option ${option_names})
    SET(${prefix}_${option} FALSE)
  ENDFOREACH(option)

  SET(current_arg_name DEFAULT_ARGS)
  SET(current_arg_list)
  FOREACH(arg ${ARGN})            
    SET(larg_names ${arg_names})    
    LIST(FIND larg_names "${arg}" is_arg_name)                   
    IF (is_arg_name GREATER -1)
      SET(${prefix}_${current_arg_name} ${current_arg_list})
      SET(current_arg_name ${arg})
      SET(current_arg_list)
    ELSE (is_arg_name GREATER -1)
      SET(loption_names ${option_names})    
      LIST(FIND loption_names "${arg}" is_option)            
      IF (is_option GREATER -1)
      SET(${prefix}_${arg} TRUE)
      ELSE (is_option GREATER -1)
      SET(current_arg_list ${current_arg_list} ${arg})
      ENDIF (is_option GREATER -1)
    ENDIF (is_arg_name GREATER -1)
  ENDFOREACH(arg)
  SET(${prefix}_${current_arg_name} ${current_arg_list})
ENDMACRO()

# Write content to file, using CONFIGURE_FILE
# The advantage compared to FILE(WRITE) is that timestamp
# does not change if file already has the same content
MACRO(CONFIGURE_FILE_CONTENT content file)
 SET(CMAKE_CONFIGURABLE_FILE_CONTENT 
  "${content}\n")
 CONFIGURE_FILE(
  ${MYSQL_CMAKE_SCRIPT_DIR}/configurable_file_content.in
  ${file}
  @ONLY)
ENDMACRO()

# Merge static libraries into a big static lib. The resulting library 
# should not not have dependencies on other static libraries.
# We use it in MySQL to merge mysys,dbug,vio etc into mysqlclient

MACRO(MERGE_STATIC_LIBS TARGET OUTPUT_NAME LIBS_TO_MERGE)
  # To produce a library we need at least one source file.
  # It is created by ADD_CUSTOM_COMMAND below and will helps 
  # also help to track dependencies.
  SET(SOURCE_FILE ${CMAKE_CURRENT_BINARY_DIR}/${TARGET}_depends.c)
  ADD_LIBRARY(${TARGET} STATIC ${SOURCE_FILE})
  SET_TARGET_PROPERTIES(${TARGET} PROPERTIES OUTPUT_NAME ${OUTPUT_NAME})

  FOREACH(LIB ${LIBS_TO_MERGE})
    GET_TARGET_PROPERTY(LIB_LOCATION ${LIB} LOCATION)
    GET_TARGET_PROPERTY(LIB_TYPE ${LIB} TYPE)
    IF(NOT LIB_LOCATION)
       # 3rd party library like libz.so. Make sure that everything
       # that links to our library links to this one as well.
       TARGET_LINK_LIBRARIES(${TARGET} ${LIB})
    ELSE()
      # This is a target in current project
      # (can be a static or shared lib)
      IF(LIB_TYPE STREQUAL "STATIC_LIBRARY")
        SET(STATIC_LIBS ${STATIC_LIBS} ${LIB_LOCATION})
        ADD_DEPENDENCIES(${TARGET} ${LIB})
      ELSE()
        # This is a shared library our static lib depends on.
        TARGET_LINK_LIBRARIES(${TARGET} ${LIB})
      ENDIF()
    ENDIF()
  ENDFOREACH()

  # Make the generated dummy source file depended on all static input
  # libs. If input lib changes,the source file is touched
  # which causes the desired effect (relink).
  ADD_CUSTOM_COMMAND( 
    OUTPUT  ${SOURCE_FILE}
    COMMAND ${CMAKE_COMMAND}  -E touch ${SOURCE_FILE}
    DEPENDS ${STATIC_LIBS})

  IF(MSVC)
    # To merge libs, just pass them to lib.exe command line.
    SET(LINKER_EXTRA_FLAGS "")
    FOREACH(LIB ${STATIC_LIBS})
      SET(LINKER_EXTRA_FLAGS "${LINKER_EXTRA_FLAGS} ${LIB}")
    ENDFOREACH()
    SET_TARGET_PROPERTIES(${TARGET} PROPERTIES STATIC_LIBRARY_FLAGS 
      "${LINKER_EXTRA_FLAGS}")
  ELSE()
    GET_TARGET_PROPERTY(TARGET_LOCATION ${TARGET} LOCATION)  
    IF(APPLE)
      # Use OSX's libtool to merge archives (ihandles universal 
      # binaries properly)
      ADD_CUSTOM_COMMAND(TARGET ${TARGET} POST_BUILD
        COMMAND rm ${TARGET_LOCATION}
        COMMAND /usr/bin/libtool -static -o ${TARGET_LOCATION} 
        ${STATIC_LIBS}
      )  
    ELSE()
      # Generic Unix, Cygwin or MinGW. In post-build step, call
      # script, that extracts objects from archives with "ar x" 
      # and repacks them with "ar r"
      SET(TARGET ${TARGET})
      CONFIGURE_FILE(
        ${MYSQL_CMAKE_SCRIPT_DIR}/merge_archives_unix.cmake.in
        ${CMAKE_CURRENT_BINARY_DIR}/merge_archives_${TARGET}.cmake 
        @ONLY
      )
      ADD_CUSTOM_COMMAND(TARGET ${TARGET} POST_BUILD
        COMMAND rm ${TARGET_LOCATION}
        COMMAND ${CMAKE_COMMAND} -P 
        ${CMAKE_CURRENT_BINARY_DIR}/merge_archives_${TARGET}.cmake
      )
    ENDIF()
  ENDIF()
ENDMACRO()

# Create libs from libs.
# Merges static libraries, creates shared libraries out of convenience libraries.
# MYSQL_MERGE_LIBRARIES(target [STATIC|SHARED|MODULE] 
#  [linklib1 .... linklibN]
#  [EXPORTS exported_func1 .... exportedFuncN]
#  [OUTPUT_NAME output_name]
#)
MACRO(MERGE_LIBRARIES)
  CMAKE_PARSE_ARGUMENTS(ARG
    "EXPORTS;OUTPUT_NAME"
    "STATIC;SHARED;MODULE"
    ${ARGN}
  )
  LIST(GET ARG_DEFAULT_ARGS 0 TARGET) 
  SET(LIBS ${ARG_DEFAULT_ARGS})
  LIST(REMOVE_AT LIBS 0)
  IF(ARG_STATIC)
    IF (NOT "${ARG_OUTPUT_NAME}")
      SET(ARG_OUTPUT_NAME ${TARGET})
    ENDIF()
    MERGE_STATIC_LIBS(${TARGET} ${ARG_OUTPUT_NAME} "${LIBS}") 
  ELSEIF(ARG_SHARED OR ARG_MODULE)
    IF(ARG_SHARED)
      SET(LIBTYPE SHARED)
    ELSE()
      SET(LIBTYPE MODULE)
    ENDIF()
    # check for non-PIC libraries
    IF(NOT _SKIP_PIC)
      FOREACH(LIB ${LIBS})
        GET_TARGET_PROPERTY(${LIB} TYPE LIBTYPE)
        IF(LIBTYPE STREQUAL "STATIC_LIBRARY")
          GET_TARGET_PROPERTY(LIB COMPILE_FLAGS LIB_COMPILE_FLAGS)
          STRING(REPLACE "${CMAKE_SHARED_LIBRARY_C_FLAGS}" 
          "<PIC_FLAG>" LIB_COMPILE_FLAGS ${LIB_COMPILE_FLAG})
          IF(NOT LIB_COMPILE_FLAGS MATCHES "<PIC_FLAG>")
            MESSAGE(FATAL_ERROR 
            "Attempted to link non-PIC static library ${LIB} to shared library ${TARGET}\n"
            "Please use ADD_CONVENIENCE_LIBRARY, instead of ADD_LIBRARY for ${LIB}"
            )
          ENDIF()
        ENDIF()
      ENDFOREACH()
    ENDIF()
    CREATE_EXPORT_FILE(SRC ${TARGET} "${EXPORTS}")
    ADD_LIBRARY(${TARGET} SHARED ${SRC})
    TARGET_LINK_LIBRARIES(${TARGET} ${LIBS})
    IF(ARG_OUTPUT_NAME)
      SET_TARGET_PROPERTIES(${TARGET} PROPERTIES OUTPUT_NAME "${ARG_OUTPUT_NAME}")
    ENDIF()
    # Disallow undefined symbols in shared libraries, but allow for modules
    # (they export from loading executable)
    IF(LIBTYPE MATCHES "SHARED" AND CMAKE_SYSTEM_TYPE MATCHES "Linux")
      SET_TARGET_PROPERTIES(${TARGET} PROPERTIES LINK_FLAGS "-Wl,--no-undefined")
    ENDIF()
  ELSE()
    MESSAGE(FATAL_ERROR "Unknown library type")
  ENDIF()
ENDMACRO()
