package javax.microedition.lcdui;

public class TextBox extends Screen {
    private String text;
    private int maxSize;
    private int constraints;

    public TextBox(String title, String text, int maxSize, int constraints) {
        setTitle(title);
        this.text = text != null ? text : "";
        this.maxSize = maxSize;
        this.constraints = constraints;
    }

    void showNative() {
        NativeBridge.formBegin(getTitle(), 3);
        NativeBridge.formAddTextField("", text, maxSize, constraints);
        java.util.ArrayList<Command> commands = getCommands();
        for (int i = 0; i < commands.size(); i++) {
            Command command = commands.get(i);
            NativeBridge.formAddCommand(command.getLabel(), command.getCommandType(),
                    command.getPriority(), i);
        }
        NativeBridge.formShow();
    }

    public String getString() { return text; }
    public void setString(String text) { this.text = text != null ? text : ""; }
    public int getMaxSize() { return maxSize; }
    public int setMaxSize(int maxSize) { this.maxSize = maxSize; return maxSize; }
    public int getConstraints() { return constraints; }
    public void setConstraints(int constraints) { this.constraints = constraints; }
    public int size() { return text.length(); }
    public void insert(String src, int position) { }
    public void delete(int offset, int length) { }
    public int getCaretPosition() { return text.length(); }
    public void setInitialInputMode(String characterSubset) { }
}
