Configuration WinTrialBuilder {
    param(
        [string[]] $computerName = "localhost"
    )

    Import-DscResource -ModuleName xHyper-V

    Node $computerName {

        WindowsFeature HyperV {
            Ensure = "Present"
            Name = "Hyper-V"
        }

        # This may not be necessary?
        xVMHost VmHostConfiguration {
            IsSingleInstance = 'Yes'

        }
    }
}

WinTrialBuilder
