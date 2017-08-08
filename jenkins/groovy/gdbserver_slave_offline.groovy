import hudson.model.*
import jenkins.model.Jenkins
import org.jvnet.jenkins.plugins.nodelabelparameter.*
import org.jvnet.jenkins.plugins.nodelabelparameter.node.*
import hudson.util.RemotingDiagnostics
import hudson.slaves.EnvironmentVariablesNodeProperty

instance = Jenkins.getInstance()
build = Thread.currentThread().executable
workspace = build.getWorkspace()
slave = workspace.toComputer()
channel = workspace.getChannel()
gdbserver = 'def proc = "pgrep gdbserver".execute(); proc.waitFor(); println proc.in.text'

result = RemotingDiagnostics.executeGroovy(gdbserver, channel)

// For some reason executeGroovy returns space when it can't find gdbserver
if (result.size() != 1) {
    println slave.name + " is running gdbserver."
    println "Taking it offline."

    slave.cliOffline("gdbserver is running")

    globalNodeProperties = instance.getGlobalNodeProperties()
    envVarsNodePropertyList = globalNodeProperties.getAll(EnvironmentVariablesNodeProperty.class)

    newEnvVarsNodeProperty = null
    envVars = null

    if (envVarsNodePropertyList == null || envVarsNodePropertyList.size() == 0) {
        newEnvVarsNodeProperty = new EnvironmentVariablesNodeProperty();
        globalNodeProperties.add(newEnvVarsNodeProperty)
        envVars = newEnvVarsNodeProperty.getEnvVars()
    } else {
        envVars = envVarsNodePropertyList.get(0).getEnvVars()
    }

    envVars.put("GDBSERVER", "gdbserver is running.")

    instance.save()
}
