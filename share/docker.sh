#!/bin/bash
#
# Copyright 2020, Marshall McMullen <marshall.mcmullen@gmail.com>
#
# This program is free software: you can redistribute it and/or modify it under the terms of the Apache License
# as published by the Apache Software Foundation, either version 2 of the License, or (at your option) any later
# version.

#-----------------------------------------------------------------------------------------------------------------------
#
# Docker
#
#-----------------------------------------------------------------------------------------------------------------------

opt_usage running_in_docker <<'END'
Check if we are running inside docker or not.
END
running_in_docker()
{
    [[ -f "/.dockerenv" ]] || grep -qw docker /proc/$$/cgroup 2>/dev/null
}

opt_usage docker_build <<'END'
docker_build is used to intelligently build a docker image from a Dockerfile.

This adds some intelligence around a vanilla docker build command so that we only build when absolutely necessary.
This is smarter than docker's built-in layer caching mechanism since that will always go to the cache and still build the
image even if it's already been built. Moreover, a vanilla docker build command doesn't try to pull before it builds.
This result in every developer having to do an initial build locally even if we've published it remotely to dockerhub.

The algorithm we employ is as follows:

    1) Look for the image locally
    2) Try to download the image from docker repository
    3) Build the docker image from scratch

This entire algorithm is built on a simple idea of essentially computingour own simplistic sha256 which corresponds to
the content of the provided Dockerfile as well as any files which are dynamically copied or added via COPY or ADD
directives in the Dockerfile. We then simply use that dynamically generated tag to easily be able to look for the image
before we try to build.

This function will create some output state files underneath ${workdir}/docker that are super useful. These are all
prefixed by ${name} which defaults to $(basename ${repo}).

    1) ${name}.options           : Options passed into docker_build
    2) ${name}.history           : Contains output of 'docker history'
    3) ${name}.inspect           : Contains output of 'docker inspect'
    4) ${name}.dockerfile        : Contains original dockerfile with all environment variables interpolated
    5) ${name}.${shafunc}        : Contains full content based sha of the dependencies to create the docker image
    6) ${name}.${shafunc}_short  : Contains first 12 characters of the full SHA of the dependencies of the image
    7) ${name}.${shafunc}_detail : Contains a detailed listing of all the dependencies that led to the creation of the
                                   docker image along with THEIR respective SHAs.

NOTE: If you want to push any tags you need to provide --username and --password arguments or have DOCKER_USERNAME and
DOCKER_PASSWORD environment variables set.

END
docker_build()
{
    $(opt_parse \
        "&build_arg                     | Build arguments to pass into lower level docker build --build-arg."          \
        ":file=Dockerfile               | The docker file to use. Defaults to Dockerfile."                             \
        ":name                          | Name to use for generated artifacts. Defaults to the basename of repo."      \
        "+pull                          | Pull the image from the remote registry/repo."                               \
        "&push                          | List of tags to push to the remote registry/repo. The special value 'builtin'
                                          indicates you want to push the content-based tag ebash auto generates.
                                          Multiple tags can be space delimited inside this array."                     \
        "+pretend                       | Do not actually build the docker image. Return 0 if image already exists and 1
                                          if the image does not exist and a build is required."                        \
        "=repo                          | Name of docker regisrty/repository for remote images."                       \
        ":shafunc=sha256                | SHA function to use. Default to sha256."                                     \
        "&tag                           | Additional tags to assign to the image in addition to the builtin content
                                          based SHA generated by ebash. Thease are of the form name:tag. This allows you
                                          to actually tag and push to multiple remote repositories in one operation.
                                          Multiple tags can be space delimited inside this array."                     \
        ":tags_url_base                 | Base docker URL to use to check for a tag. By default this uses dockerhub and
                                          will append your registry/repo to the base URL. The base URL we use is
                                          'https://hub.docker.com/v2/repositories' and we append a suffix of '/tags'.
                                          With a repo of 'liqid/liqid' we would thus use
                                          'https://hub.docker.com/v2/repositories/liqid/liqid/tags'"                   \
        ":tags_url_full                 | In the event you need more control over the URL used for looking up a docker
                                          tag than offered by tags_url_base, you can give the fully qualified URL
                                          we should use for looking up docker tagss."                                  \
        ":username=${DOCKER_USERNAME:-} | Username for pushing images to the registry/repo. Defaults to DOCKER_USERNAME
                                          environment variable"                                                        \
        ":password=${DOCKER_PASSWORD:-} | Password for pushing images to the registry/repo. Defaults to DOCKER_PASSWORD
                                          environment variable"                                                        \
        ":workdir=.work/docker          | Temporary work directory to save output files to."                           \
    )

    mkdir -p "${workdir}"
    assert_exists "${file}"

    : ${name:="$(basename "${repo}")"}
    local options="${workdir}/${name}.options"
    local history="${workdir}/${name}.history"
    local inspect="${workdir}/${name}.inspect"
    local shafile="${workdir}/${name}.${shafunc}"
    local shafile_short="${workdir}/${name}.${shafunc}_short"
    local shafile_detail="${workdir}/${name}.${shafunc}_detail"
    opt_dump | sort > "${options}"

    # Add any build arguments into sha_detail
    local entry="" build_arg_keys=() build_arg_key="" build_arg_val=""
    for entry in "${build_arg[@]}"; do
        build_arg_key="${entry%%=*}"
        build_arg_val="${entry#*=}"
        edebug "buildarg: $(lval entry build_arg_key build_arg_val)"

        eval "export ${build_arg_key}=${build_arg_val}"
        build_arg_keys+=( "\$${build_arg_key}" )
        build_arg_vals+=( "--build-arg ${entry}" )
    done

    local dockerfile="${workdir}/${name}.dockerfile"
    envsubst "$(array_join build_arg_keys ,)" < "${file}" > "${dockerfile}"

    # Strip out ARGs that we've interpolated
    for entry in "${build_arg[@]}"; do
        build_arg_key="${entry%%=*}"
        edebug "stripping buildarg: $(lval entry build_arg_key)"
        sed -i -e "/ARG ${build_arg_key}/d" "${dockerfile}"
    done

    # Show the interpolated file
    edebug "envsubst expanded: $(lval file dockerfile)"
    cat "${dockerfile}" | edebug

    # Dynamically compute dependency SHA of dockerfile
    depends=(
        ${dockerfile}
        $(grep -P "^(ADD|COPY) " "${dockerfile}" | awk '{$1=$NF=""}1' | sed 's|"||g' || true)
    )

    edebug "$(lval depends)"
    sha_detail="$(array_join_nl build_arg_vals)
    $(find ${depends[@]} -type f -print0 \
        | sort -z \
        | xargs -0 "${shafunc}sum" \
        | awk '{print $2"'@${shafunc}:'"$1}'
    )"

    edebug "$(lval sha_detail)"
    echo "${sha_detail}" > "${shafile_detail}"
    echo "${sha_detail}" | "${shafunc}sum" | awk '{print "'${shafunc}':"$1}' > "${shafile}"
    sha=$(cat "${shafile}")
    sha_short="$(string_truncate 12 "${sha#*:}")"
    echo "${sha_short}" > "${shafile_short}"

    # Image we should look for
    image="${repo}:${sha_short}"
    edebug $(lval      \
        build_arg      \
        build_arg_keys \
        build_arg_vals \
        dockerfile     \
        file           \
        history        \
        image          \
        inspect        \
        pretend        \
        push           \
        repo           \
        sha            \
        sha_short      \
        shafile        \
        shafile_detail \
        shafile_short  \
        shafunc        \
        tag            \
        tags_url_base  \
        tags_url_full  \
        workdir        \
    )

    # Look for image locally first
    if [[ -n "$(docker images --quiet "${image}" 2>/dev/null)" ]]; then
        checkbox "Using local ${image}"
        docker inspect "${image}" > "${inspect}"
        return 0
    elif [[ "${pull}" -eq 1 ]]; then
        if docker pull "${image}" 2>/dev/null; then
            checkbox "Using pulled ${image}"
            docker inspect "${image}" > "${inspect}"
            return 0
        fi
    elif [[ "${pull}" -eq 0 ]]; then

        local docker_url=""
        if [[ -n "${tags_url_full}" ]]; then
            docker_url="${tags_url_full}/${sha_short}/"
        elif [[ -n "${tags_url_base}" ]]; then
            docker_url="${tags_url_base}/${repo}/tags/${sha_short}/"
        else
            docker_url="https://hub.docker.com/v2/repositories/${repo}/tags/${sha_short}/"
        fi

        edebug "Checking remote $(lval docker_url)"

        if curl --silent -f --head -lL "${docker_url}" &>/dev/null; then
            checkbox "Remote exists ${image}"
            return 0
        fi
    fi

    if [[ "${pretend}" -eq 1 ]]; then
        ewarn "Build required for $(lval image) but pretend=1"
        return 1
    fi

    eprogress "Building docker $(lval image tag)"

    docker build --tag "${image}" --file "${dockerfile}" . | edebug

    eprogress_kill

    # Also tag with custom tags if requested
    local entry entries
    array_init entries "${tag[*]}"
    edebug "$(lval tag entries)"
    for entry in "${entries[@]}"; do
        [[ -z "${entry}" ]] && continue
        einfo "Tagging with custom $(lval tag=entry)"
        docker build --tag "${entry}" --file "${dockerfile}" . | edebug
    done

    einfo "Size"
    docker images "${image}"

    einfo "Layers"
    docker history "${image}" | tee "${history}"

    if array_not_empty push; then

        argcheck username password
        echo "${password}" | docker login --username "${username}" --password-stdin

        array_init entries "${push[*]}"
        edebug "Pushing $(lval push entries)"
        for entry in "${entries[@]}"; do
            [[ "${entry}" == "builtin" ]] && entry="${image}"

            # Make sure the provided tag they want us to push is one we built
            assert array_contains tag "${entry}"
            einfo "Pushing $(lval tag=entry)"
            docker push "${entry}"
        done
    fi

    # Only create inspect (stamp) file at the very end after everything has been done.
    einfo "Creating stamp file ${inspect}"
    docker inspect "${image}" > "${inspect}"
}
