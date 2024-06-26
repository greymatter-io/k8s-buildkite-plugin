local identity = function(f) f;

local numberSuffix(s) =
  local t = std.split(s, '_');
  std.format('%05s', t[std.length(t) - 1]);

local labelChars = std.set(std.stringChars('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'));
local labelValue(s) =
  local sanitizedValue = std.join('', [
    if std.setMember(c, labelChars) then c else ''
    for c in std.stringChars(s)
  ]);
  if std.length(sanitizedValue) < 63 then sanitizedValue else std.substr(sanitizedValue, 0, 63);

function(jobName, agentEnv={}, stepEnvFile='', patchFunc=identity) patchFunc({
  local buildSubPath = std.join('/', [
    env.BUILDKITE_AGENT_NAME,
    env.BUILDKITE_ORGANIZATION_SLUG,
    env.BUILDKITE_PIPELINE_SLUG,
  ]),

  local env = {
    BUILDKITE_TIMEOUT: '10',
    BUILDKITE_PLUGIN_K8S_SECRET_NAME: 'buildkite',
    BUILDKITE_PLUGIN_K8S_DEFAULT_SECRET_NAME: '',
    BUILDKITE_PLUGIN_K8S_GIT_CREDENTIALS_SECRET_KEY: '',
    BUILDKITE_PLUGIN_K8S_GIT_CREDENTIALS_SECRET_NAME: '',
    BUILDKITE_PLUGIN_K8S_GIT_SSH_SECRET_KEY: '',
    BUILDKITE_PLUGIN_K8S_GIT_SSH_SECRET_NAME: '',
    BUILDKITE_PLUGIN_K8S_AGENT_TOKEN_SECRET_KEY: 'buildkite-agent-token',
    BUILDKITE_PLUGIN_K8S_INIT_IMAGE: 'embarkstudios/k8s-buildkite-agent@sha256:1d88791315ed6b0b49a64055bc71c5a9a0b1953e387f99d25299ed06ccea5dbd',
    BUILDKITE_PLUGIN_K8S_ALWAYS_PULL: false,
    BUILDKITE_PLUGIN_K8S_IMAGE_PULL_SECRET: '',
    BUILDKITE_PLUGIN_K8S_MOUNT_PATH_EXTERNAL_SECRETS: "/externalsecrets",
    BUILDKITE_PLUGIN_K8S_BUILD_PATH_HOST_PATH: '',
    BUILDKITE_PLUGIN_K8S_BUILD_PATH_PVC: '',
    BUILDKITE_PLUGIN_K8S_GIT_MIRRORS_HOST_PATH: '',
    BUILDKITE_PLUGIN_K8S_RUN_AS_USER: '',
    BUILDKITE_PLUGIN_K8S_RUN_AS_GROUP: '',
    BUILDKITE_PLUGIN_K8S_MOUNT_SECRET: '',
    BUILDKITE_PLUGIN_K8S_MOUNT_BUILDKITE_AGENT: 'true',
    BUILDKITE_PLUGIN_K8S_PRIVILEGED: 'false',
    BUILDKITE_PLUGIN_K8S_RESOURCES_REQUEST_CPU: '',
    BUILDKITE_PLUGIN_K8S_RESOURCES_LIMIT_CPU: '',
    BUILDKITE_PLUGIN_K8S_RESOURCES_REQUEST_MEMORY: '',
    BUILDKITE_PLUGIN_K8S_RESOURCES_LIMIT_MEMORY: '',
    BUILDKITE_PLUGIN_K8S_SERVICE_ACCOUNT_NAME: 'default',
    BUILDKITE_PLUGIN_K8S_WORKDIR: std.join('/', [env.BUILDKITE_BUILD_PATH, buildSubPath]),
    BUILDKITE_PLUGIN_K8S_JOB_TTL_SECONDS_AFTER_FINISHED: '86400',
    BUILDKITE_PLUGIN_K8S_JOB_BACKOFF_LIMIT: '0',
  } + agentEnv,

  local stepEnv =
    [
      {
        local kv = std.splitLimit(l, '=', 1),
        name: kv[0],
        value: std.parseJson(kv[1]),
      }
      for l in std.split(stepEnvFile, '\n')
      if l != '' && !std.startsWith(l, 'BUILDKITE')
    ],

  local podEnv =
    stepEnv +
    [
      { name: f, value: env[f] }
      for f in std.objectFields(agentEnv)
      if std.startsWith(f, 'BUILDKITE')
    ] +
    [
      {
        name: 'BUILDKITE_AGENT_TOKEN',
        valueFrom: {
          secretKeyRef: if env.BUILDKITE_PLUGIN_K8S_DEFAULT_SECRET_NAME != ''
          then {
            name: env.BUILDKITE_PLUGIN_K8S_DEFAULT_SECRET_NAME,
            key: 'buildkite-agent-token',
          }
          else {
            name: env.BUILDKITE_PLUGIN_K8S_SECRET_NAME,
            key: env.BUILDKITE_PLUGIN_K8S_AGENT_TOKEN_SECRET_KEY,
          },
        },
      },
    ] + [
      {
        local kv = std.splitLimit(env[f], '=', 1),
        name: kv[0],
        value: kv[1],
      }
      for f in std.sort(std.objectFields(env), numberSuffix)
      if std.startsWith(f, 'BUILDKITE_PLUGIN_K8S_ENVIRONMENT_')
         && !std.startsWith(f, 'BUILDKITE_PLUGIN_K8S_ENVIRONMENT_FROM_SECRET')
    ] + [
      {name: 'BUILDKITE_PLUGIN_K8S_IS_JOB', value: 'true'},
    ],

  local secretEnv =
    [
      { secretRef: { name: env[f] } }
      for f in std.objectFields(env)
      if std.startsWith(f, 'BUILDKITE_PLUGIN_K8S_ENVIRONMENT_FROM_SECRET')
    ],

  local initSecretEnv =
    [
      { secretRef: { name: env[f] } }
      for f in std.objectFields(env)
      if std.startsWith(f, 'BUILDKITE_PLUGIN_K8S_INIT_ENVIRONMENT_FROM_SECRET')
    ],

  local labels = {
    'build/branch': labelValue(env.BUILDKITE_BRANCH),
    'build/pipeline': labelValue(env.BUILDKITE_PIPELINE_SLUG),
    'buildkite/plugin': 'k8s',
  },

  local annotations = {
    'build/commit': env.BUILDKITE_COMMIT,
    'build/creator': env.BUILDKITE_BUILD_CREATOR,
    'build/creator-email': env.BUILDKITE_BUILD_CREATOR_EMAIL,
    'build/id': env.BUILDKITE_BUILD_ID,
    'build/url': env.BUILDKITE_BUILD_URL,
    'build/number': env.BUILDKITE_BUILD_NUMBER,
    'build/organization': env.BUILDKITE_ORGANIZATION_SLUG,
    'build/repo': env.BUILDKITE_REPO,
    'build/source': env.BUILDKITE_SOURCE,
    'buildkite/agent-id': env.BUILDKITE_AGENT_ID,
    'buildkite/agent-name': env.BUILDKITE_AGENT_NAME,
    'buildkite/job-id': env.BUILDKITE_JOB_ID,
    'buildkite/step-id': env.BUILDKITE_STEP_ID,
    'buildkite/step-key': env.BUILDKITE_STEP_KEY,
    'job-name': jobName,
    [if std.objectHas(env, "BUILDKITE_BUILD_CREATOR_TEAMS") then 'build/creator-teams' else null]: env.BUILDKITE_BUILD_CREATOR_TEAMS,
  },

  local buildVolume =
    if env.BUILDKITE_PLUGIN_K8S_BUILD_PATH_PVC != ''
    then { persistentVolumeClaim: { claimName: env.BUILDKITE_PLUGIN_K8S_BUILD_PATH_PVC } }
    else if env.BUILDKITE_PLUGIN_K8S_BUILD_PATH_HOST_PATH != ''
    then { hostPath: { path: env.BUILDKITE_PLUGIN_K8S_BUILD_PATH_HOST_PATH, type: 'DirectoryOrCreate' } }
    else { emptyDir: {} }
  ,

  local gitMirrorsVolume =
    if env.BUILDKITE_PLUGIN_K8S_GIT_MIRRORS_HOST_PATH != ''
    then { hostPath: { path: env.BUILDKITE_PLUGIN_K8S_GIT_MIRRORS_HOST_PATH, type: 'DirectoryOrCreate' } }
    else { emptyDir: {} }
  ,

  local defaultSecretsMounts = {
    mount:
      if env.BUILDKITE_PLUGIN_K8S_DEFAULT_SECRET_NAME == '' then []
      else [{ mountPath: '/secrets/', name: 'default-secrets' }],
    volume:
      if env.BUILDKITE_PLUGIN_K8S_DEFAULT_SECRET_NAME == '' then []
      else [{
        name: 'default-secrets',
        secret: {
          defaultMode: 256,
          secretName: env.BUILDKITE_PLUGIN_K8S_DEFAULT_SECRET_NAME,
          items: [
            { key: 'git-credentials', path: 'git-credentials' },
            { key: 'ssh-key', path: 'ssh-key' },
          ],
        },
      }],
  },

  local gitCredentials = {
    mount:
      if env.BUILDKITE_PLUGIN_K8S_GIT_CREDENTIALS_SECRET_KEY == '' then []
      else [{ mountPath: '/secrets/git-credentials', name: 'git-credentials', subPath: 'git-credentials' }],
    volume:
      if env.BUILDKITE_PLUGIN_K8S_GIT_CREDENTIALS_SECRET_KEY == '' then []
      else [{
        name: 'git-credentials',
        secret: {
          defaultMode: 256,
          secretName:
            if env.BUILDKITE_PLUGIN_K8S_GIT_CREDENTIALS_SECRET_NAME != ''
            then env.BUILDKITE_PLUGIN_K8S_GIT_CREDENTIALS_SECRET_NAME
            else env.BUILDKITE_PLUGIN_K8S_SECRET_NAME,
          items: [{ key: env.BUILDKITE_PLUGIN_K8S_GIT_CREDENTIALS_SECRET_KEY, path: 'git-credentials' }],
        },
      }],
  },

  local gitSSH = {
    mount:
      if env.BUILDKITE_PLUGIN_K8S_GIT_SSH_SECRET_KEY == '' then []
      else [{ mountPath: '/secrets/ssh-key', name: 'git-ssh-key', subPath: 'ssh-key' }],
    volume:
      if env.BUILDKITE_PLUGIN_K8S_GIT_SSH_SECRET_KEY == '' then []
      else [{
        name: 'git-ssh-key',
        secret: {
          defaultMode: 256,
          secretName:
            if env.BUILDKITE_PLUGIN_K8S_GIT_SSH_SECRET_NAME != ''
            then env.BUILDKITE_PLUGIN_K8S_GIT_SSH_SECRET_NAME
            else env.BUILDKITE_PLUGIN_K8S_SECRET_NAME,
          items: [{ key: env.BUILDKITE_PLUGIN_K8S_GIT_SSH_SECRET_KEY, path: 'ssh-key' }],
        },
      }],
  },

  local hostPathMount = {
    local cfg =
      std.mapWithIndex(
        function(i, v) ['hostpath-' + i] + v,
        [
          std.splitLimit(env[f], ':', 1)
          for f in std.objectFields(env)
          if std.startsWith(f, 'BUILDKITE_PLUGIN_K8S_MOUNT_HOSTPATH')
             && env[f] != ''
        ]
      ),
    mount: [
      { name: c[0], mountPath: c[2] }
      for c in cfg
    ],
    volume: [
      { name: c[0], hostPath: { path: c[1], type: 'DirectoryOrCreate' } }
      for c in cfg
    ],
  },

  local secretMount = {
    local cfg = [
      std.splitLimit(env[f], ':', 1)
      for f in std.objectFields(env)
      if std.startsWith(f, 'BUILDKITE_PLUGIN_K8S_MOUNT_SECRET')
         && env[f] != ''
    ],
    mount: [
      { name: c[0], mountPath: c[1] }
      for c in cfg 
    ],
    volume: [
      { name: c[0], secret: { secretName: c[0], defaultMode: 256 } }
      for c in cfg 
    ]
  },

  local externalSecrets = {
    local cfg = [
      env[f]
      for f in std.objectFields(env)
      if std.startsWith(f, 'BUILDKITE_PLUGIN_K8S_EXTERNAL_SECRETS')
        && env[f] != ''
    ],

    mount: if std.length(cfg) > 0 then [
      { name: 'externalsecrets', mountPath: env.BUILDKITE_PLUGIN_K8S_MOUNT_PATH_EXTERNAL_SECRETS }
    ] else [],
    volume: if std.length(cfg) > 0 then [
      { name: 'externalsecrets', secret: { secretName: jobName, defaultMode: 256}, }
    ] else [],
  },


  local agentMount =
    if env.BUILDKITE_PLUGIN_K8S_MOUNT_BUILDKITE_AGENT == 'false'
    then []
    else [{
      name: 'buildkite-agent',
      mountPath: '/usr/local/bin/buildkite-agent',
      subPath: 'buildkite-agent',
    }],

  local commandArgs =
    if env.BUILDKITE_COMMAND != '' then {
      command: ['/bin/sh', '-c'],
      args: [env.BUILDKITE_COMMAND],
    } else {
      command: [env[f] for f in std.sort(std.objectFields(env), numberSuffix) if std.startsWith(f, 'BUILDKITE_PLUGIN_K8S_ENTRYPOINT_')],
      args: [env[f] for f in std.sort(std.objectFields(env), numberSuffix) if std.startsWith(f, 'BUILDKITE_PLUGIN_K8S_COMMAND_')],
    },

  local initContainers =
    if env.BUILDKITE_PLUGIN_K8S_INIT_IMAGE == '' then []
    else [{
      name: 'bootstrap',
      image: env.BUILDKITE_PLUGIN_K8S_INIT_IMAGE,
      args: ['bootstrap', '--experiment=git-mirrors', '--git-mirrors-path=/git-mirrors', '--ssh-keyscan', '--command', 'true'],
      env: podEnv,
      envFrom: initSecretEnv,
      volumeMounts: [
        { mountPath: env.BUILDKITE_BUILD_PATH, name: 'build' },
        { mountPath: '/git-mirrors', name: 'git-mirrors' },
        { mountPath: '/local', name: 'buildkite-agent' },
      ] + gitCredentials.mount + gitSSH.mount + defaultSecretsMounts.mount,
    }],

  local deadline = std.parseInt(env.BUILDKITE_TIMEOUT) * 60,

  local imagePullSecrets =
    if env.BUILDKITE_PLUGIN_K8S_IMAGE_PULL_SECRET == '' then []
    else [
        {name: env.BUILDKITE_PLUGIN_K8S_IMAGE_PULL_SECRET},
    ],


  local runAsUser =
    if env.BUILDKITE_PLUGIN_K8S_RUN_AS_USER == '' then {}
    else
      {runAsUser: std.parseInt(env.BUILDKITE_PLUGIN_K8S_RUN_AS_USER)},

  local runAsGroup =
    if env.BUILDKITE_PLUGIN_K8S_RUN_AS_GROUP == '' then {}
    else
      {runAsGroup: std.parseInt(env.BUILDKITE_PLUGIN_K8S_RUN_AS_GROUP)},

  apiVersion: 'batch/v1',
  kind: 'Job',
  metadata: {
    name: jobName,
    labels: labels,
    annotations: annotations,
  },
  spec: {
    backoffLimit: std.parseInt(env.BUILDKITE_PLUGIN_K8S_JOB_BACKOFF_LIMIT),
    activeDeadlineSeconds: deadline,
    completions: 1,
    ttlSecondsAfterFinished: std.parseInt(env.BUILDKITE_PLUGIN_K8S_JOB_TTL_SECONDS_AFTER_FINISHED),
    template: {
      metadata: {
        labels: labels,
        # Take all the same annotations as the job itself on the pod, but also add the istio inject false annotation
        # Istio gets in the way of many jobs
        annotations: annotations { 'sidecar.istio.io/inject': 'false' },
      },
      spec: {
        nodeSelector: {
          "greymatter.io/build-system": "builders",
        },
        tolerations: [
          {
            key: "greymatter.io/build-system",
            operator: "Equal",
            value: "builders",
            effect: "NoSchedule"
          }
        ],
        activeDeadlineSeconds: deadline,
        restartPolicy: 'Never',
        serviceAccountName: env.BUILDKITE_PLUGIN_K8S_SERVICE_ACCOUNT_NAME,
        initContainers: initContainers,
        imagePullSecrets: imagePullSecrets,
        securityContext: {}
        + runAsGroup + runAsUser,
        containers: [
          {
            name: 'step',
            image: env.BUILDKITE_PLUGIN_K8S_IMAGE,
            imagePullPolicy: if env.BUILDKITE_PLUGIN_K8S_ALWAYS_PULL == 'true' then 'Always' else 'IfNotPresent',
            env: podEnv,
            envFrom: secretEnv,
            securityContext: {
              privileged: std.asciiLower(env.BUILDKITE_PLUGIN_K8S_PRIVILEGED) == 'true',
            },
            resources: {
              requests:
                (if env.BUILDKITE_PLUGIN_K8S_RESOURCES_REQUEST_CPU != '' then
                   { cpu: env.BUILDKITE_PLUGIN_K8S_RESOURCES_REQUEST_CPU }
                 else {})
                +
                (if env.BUILDKITE_PLUGIN_K8S_RESOURCES_REQUEST_MEMORY != '' then
                   { memory: env.BUILDKITE_PLUGIN_K8S_RESOURCES_REQUEST_MEMORY }
                 else {}),
              limits:
                (if env.BUILDKITE_PLUGIN_K8S_RESOURCES_LIMIT_CPU != '' then
                   { cpu: env.BUILDKITE_PLUGIN_K8S_RESOURCES_LIMIT_CPU }
                 else {})
                +
                (if env.BUILDKITE_PLUGIN_K8S_RESOURCES_LIMIT_MEMORY != '' then
                   { memory: env.BUILDKITE_PLUGIN_K8S_RESOURCES_LIMIT_MEMORY }
                 else {}),
            },
            volumeMounts: [
              { mountPath: env.BUILDKITE_PLUGIN_K8S_WORKDIR, name: 'build', subPath: buildSubPath },
              { mountPath: '/build', name: 'build', subPath: buildSubPath },
              { mountPath: '/git-mirrors', name: 'git-mirrors' },
            ] + secretMount.mount + externalSecrets.mount + hostPathMount.mount + agentMount,
            workingDir: '/build',
          } + commandArgs,
        ],
        volumes: [
          { name: 'build' } + buildVolume,
          { name: 'git-mirrors' } + gitMirrorsVolume,
          { name: 'buildkite-agent', emptyDir: {} },
        ] + gitCredentials.volume + gitSSH.volume + secretMount.volume + externalSecrets.volume + hostPathMount.volume + defaultSecretsMounts.volume,
      },
    },
  },
})
