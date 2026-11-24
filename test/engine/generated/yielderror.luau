local task = zune.task

task.wait(1)

error("This is an error in async require")

return true
