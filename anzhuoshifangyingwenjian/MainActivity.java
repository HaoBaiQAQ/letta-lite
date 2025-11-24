package com.letta.app;

import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;
import android.app.Activity;

public class MainActivity extends Activity {
    // 加载Rust核心.so库
    static {
        System.loadLibrary("letta-core");
    }

    private EditText inputEdit;
    private TextView resultView;
    private Button sendBtn, allowBtn, denyBtn;
    private long ctx;

    // Rust核心库的Native接口
    public native long letta_init();
    public native String letta_send_input(long ctx, String input);
    public native String letta_confirm_tool(long ctx, boolean confirm);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        // 绑定UI控件
        inputEdit = findViewById(R.id.inputEdit);
        resultView = findViewById(R.id.resultView);
        sendBtn = findViewById(R.id.sendBtn);
        allowBtn = findViewById(R.id.allowBtn);
        denyBtn = findViewById(R.id.denyBtn);

        // 初始化Rust核心
        ctx = letta_init();

        // 发送按钮点击事件
        sendBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                String input = inputEdit.getText().toString().trim();
                if (!input.isEmpty()) {
                    inputEdit.setText("");
                    String result = letta_send_input(ctx, input);
                    resultView.setText(result);
                    if (result.contains("是否允许") || result.contains("需要调用")) {
                        allowBtn.setVisibility(View.VISIBLE);
                        denyBtn.setVisibility(View.VISIBLE);
                    } else {
                        allowBtn.setVisibility(View.GONE);
                        denyBtn.setVisibility(View.GONE);
                    }
                }
            }
        });

        // 允许工具调用
        allowBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                resultView.setText(letta_confirm_tool(ctx, true));
                allowBtn.setVisibility(View.GONE);
                denyBtn.setVisibility(View.GONE);
            }
        });

        // 拒绝工具调用
        denyBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                resultView.setText(letta_confirm_tool(ctx, false));
                allowBtn.setVisibility(View.GONE);
                denyBtn.setVisibility(View.GONE);
            }
        });
    }
}
