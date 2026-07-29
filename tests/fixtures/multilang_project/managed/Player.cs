using System.Runtime.InteropServices;

public partial class Player : BaseActor
{
    private BaseActor owner;

    [DllImport("demo")]
    private static extern void demo_ping();
}
